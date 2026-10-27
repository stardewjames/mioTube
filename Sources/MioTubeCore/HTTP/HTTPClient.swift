import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum MioTubeError: Error, Sendable, Equatable {
  case http(status: Int, body: String)
  case transport(String)
  case decoding(String)
  case unauthorized
  case notSignedIn
  case invalidResponse(String)
}

public enum HTTPMethod: String, Sendable {
  case get = "GET"
  case post = "POST"
}

public struct HTTPRequest: Sendable {
  public var method: HTTPMethod
  public var url: URL
  public var headers: [String: String]
  public var body: Data?
  public var timeout: TimeInterval

  public init(
    method: HTTPMethod = .get,
    url: URL,
    headers: [String: String] = [:],
    body: Data? = nil,
    timeout: TimeInterval = 20
  ) {
    self.method = method
    self.url = url
    self.headers = headers
    self.body = body
    self.timeout = timeout
  }
}

public struct HTTPResponse: Sendable {
  public let status: Int
  public let data: Data
  public let headers: [String: String]

  public init(status: Int, data: Data, headers: [String: String] = [:]) {
    self.status = status
    self.data = data
    self.headers = headers
  }

  /// Case-insensitive header lookup.
  public func header(_ name: String) -> String? {
    let lower = name.lowercased()
    return headers.first { $0.key.lowercased() == lower }?.value
  }
}

/// Every network call in the package goes through this seam so tests can stub or spy on it.
/// Implementations throw `MioTubeError.http` for non-2xx responses.
public protocol HTTPTransport: Sendable {
  func send(_ r: HTTPRequest) async throws -> HTTPResponse
}

public protocol RequestInterceptor: Sendable {
  func intercept(_ r: inout HTTPRequest) async
}

/// Pure retry rules so they can be tested without a network.
public struct RetryPolicy: Sendable {
  public var delays: [TimeInterval]
  public var maxJitter: TimeInterval
  public var maxRetryAfter: TimeInterval

  public static let standard = RetryPolicy(delays: [0.5, 1.5, 4], maxJitter: 0.3, maxRetryAfter: 30)

  public init(delays: [TimeInterval], maxJitter: TimeInterval, maxRetryAfter: TimeInterval) {
    self.delays = delays
    self.maxJitter = maxJitter
    self.maxRetryAfter = maxRetryAfter
  }

  public static let retryableStatuses: Set<Int> = [429, 500, 502, 503, 504]

  public static func isRetryable(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost: true
    default: false
    }
  }

  /// Delay before retry number `retry` (0-based), or nil when retries are exhausted.
  public func delay(forRetry retry: Int, retryAfterHeader: String?) -> TimeInterval? {
    guard retry < delays.count else { return nil }
    if let header = retryAfterHeader, let seconds = TimeInterval(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
      return min(seconds, maxRetryAfter)
    }
    return delays[retry] + TimeInterval.random(in: 0...maxJitter)
  }
}

public actor URLSessionTransport: HTTPTransport {
  private let session: URLSession
  private let interceptors: [any RequestInterceptor]
  private let policy: RetryPolicy

  public init(interceptors: [any RequestInterceptor] = [], policy: RetryPolicy = .standard) {
    let config = URLSessionConfiguration.default
    config.httpMaximumConnectionsPerHost = 6
    #if !canImport(FoundationNetworking)
    config.waitsForConnectivity = true
    // Bounds the connectivity wait so offline playback fails fast instead of hanging.
    config.timeoutIntervalForResource = 25
    #endif
    #if canImport(FoundationNetworking)
    config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20, diskPath: "MioTubeHTTP")
    #else
    config.urlCache = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
    #endif
    // Cookies are attached explicitly per request (session cookies come from the Keychain).
    config.httpShouldSetCookies = false
    config.httpCookieAcceptPolicy = .never
    self.session = URLSession(configuration: config)
    self.interceptors = interceptors
    self.policy = policy
  }

  public func send(_ r: HTTPRequest) async throws -> HTTPResponse {
    var request = r
    for interceptor in interceptors {
      await interceptor.intercept(&request)
    }
    let urlRequest = Self.makeURLRequest(request)
    var retry = 0
    while true {
      do {
        let response = try await perform(urlRequest)
        if (200..<300).contains(response.status) { return response }
        if RetryPolicy.retryableStatuses.contains(response.status),
           let delay = policy.delay(forRetry: retry, retryAfterHeader: response.header("Retry-After")) {
          retry += 1
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          continue
        }
        throw MioTubeError.http(status: response.status, body: String(decoding: response.data.prefix(2048), as: UTF8.self))
      } catch let error as URLError {
        if RetryPolicy.isRetryable(error), let delay = policy.delay(forRetry: retry, retryAfterHeader: nil) {
          retry += 1
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
          continue
        }
        throw MioTubeError.transport(error.localizedDescription)
      }
    }
  }

  static func makeURLRequest(_ r: HTTPRequest) -> URLRequest {
    var urlRequest = URLRequest(url: r.url, timeoutInterval: r.timeout)
    urlRequest.httpMethod = r.method.rawValue
    urlRequest.httpBody = r.body
    for (name, value) in r.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    return urlRequest
  }

  private func perform(_ request: URLRequest) async throws -> HTTPResponse {
    try await withCheckedThrowingContinuation { continuation in
      let task = session.dataTask(with: request) { data, response, error in
        if let error {
          continuation.resume(throwing: (error as? URLError) ?? URLError(.unknown))
          return
        }
        guard let http = response as? HTTPURLResponse else {
          continuation.resume(throwing: URLError(.badServerResponse))
          return
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
          if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        continuation.resume(returning: HTTPResponse(status: http.statusCode, data: data ?? Data(), headers: headers))
      }
      task.resume()
    }
  }
}
