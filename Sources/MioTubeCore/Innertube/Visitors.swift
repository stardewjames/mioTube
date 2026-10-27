import Foundation

public struct InnertubeConfig: Sendable, Equatable {
  public var clientVersion: String?
  public var visitorData: String?
  public var fetchedAt: Date

  public init(clientVersion: String?, visitorData: String?, fetchedAt: Date) {
    self.clientVersion = clientVersion
    self.visitorData = visitorData
    self.fetchedAt = fetchedAt
  }

  /// Extracts `INNERTUBE_CLIENT_VERSION` and `VISITOR_DATA` from youtube.com HTML.
  public static func scrape(_ html: String, at date: Date = Date()) -> InnertubeConfig {
    InnertubeConfig(
      clientVersion: firstCapture(in: html, key: "INNERTUBE_CLIENT_VERSION"),
      visitorData: firstCapture(in: html, key: "VISITOR_DATA"),
      fetchedAt: date
    )
  }

  static func firstCapture(in html: String, key: String) -> String? {
    let marker = "\"\(key)\":\""
    guard let start = html.range(of: marker) else { return nil }
    let rest = html[start.upperBound...]
    guard let end = rest.firstIndex(of: "\"") else { return nil }
    let value = String(rest[..<end])
    return value.isEmpty ? nil : value
  }
}

/// Fetches the live WEB client version and a visitor id from youtube.com, cached for 24 h.
/// Concurrent callers share one in-flight fetch. Never throws: failures leave the pinned
/// profile values in effect.
public actor InnertubeConfigProvider {
  private let transport: any HTTPTransport
  private let userAgent: String
  private let ttl: TimeInterval
  private var cached: InnertubeConfig?
  private var inFlight: Task<InnertubeConfig?, Never>?

  public init(transport: any HTTPTransport, userAgent: String, ttl: TimeInterval = 24 * 3600) {
    self.transport = transport
    self.userAgent = userAgent
    self.ttl = ttl
  }

  public var current: InnertubeConfig? { cached }

  public func config() async -> InnertubeConfig? {
    if let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl { return cached }
    if let inFlight { return await inFlight.value }
    let transport = transport
    let userAgent = userAgent
    let task = Task<InnertubeConfig?, Never> {
      let request = HTTPRequest(
        url: URL(string: "https://www.youtube.com/?hl=en")!,
        headers: [
          "User-Agent": userAgent,
          "Accept-Language": "en-US,en;q=0.9",
          // Pre-accepted consent so EU visitors receive the app page, not consent.youtube.com.
          "Cookie": "SOCS=CAI",
        ],
        timeout: 15
      )
      guard let response = try? await transport.send(request) else { return nil }
      let config = InnertubeConfig.scrape(String(decoding: response.data, as: UTF8.self))
      return (config.clientVersion == nil && config.visitorData == nil) ? nil : config
    }
    inFlight = task
    let result = await task.value
    inFlight = nil
    if let result { cached = result }
    return result ?? cached
  }

  /// Drops the cached value so the next `config()` refetches (Diagnostics "Re-probe").
  public func invalidate() {
    cached = nil
  }
}
