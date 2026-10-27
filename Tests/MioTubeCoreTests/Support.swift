import Foundation
@testable import MioTubeCore

enum Fixture {
  static func data(_ name: String) throws -> Data {
    guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures") else {
      throw MioTubeError.invalidResponse("missing fixture \(name)")
    }
    return try Data(contentsOf: url)
  }

  static func json(_ name: String) throws -> JSONValue {
    try JSONValue.decode(data(name))
  }
}

/// Records every request; answers with a handler.
final class SpyTransport: HTTPTransport, @unchecked Sendable {
  private let lock = NSLock()
  private var _requests: [HTTPRequest] = []
  private let handler: @Sendable (HTTPRequest) throws -> HTTPResponse

  init(handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
    self.handler = handler
  }

  /// Serves a fixed body for every request.
  convenience init(status: Int = 200, body: Data) {
    self.init { _ in
      if (200..<300).contains(status) { return HTTPResponse(status: status, data: body) }
      throw MioTubeError.http(status: status, body: "")
    }
  }
  var requests: [HTTPRequest] {
    lock.withLock { _requests }
  }

  func send(_ r: HTTPRequest) async throws -> HTTPResponse {
    lock.withLock { _requests.append(r) }
    return try handler(r)
  }
}

extension HTTPRequest {
  var jsonBody: JSONValue? { body.flatMap { try? JSONValue.decode($0) } }
}

func testCatalog() throws -> ProfileCatalog { try ProfileCatalog.bundled() }

func makeClient(_ transport: any HTTPTransport, session: GoogleSession? = nil) throws -> InnertubeClient {
  InnertubeClient(
    transport: transport, catalog: try testCatalog(), session: InMemorySessionStore(session), locale: .enUS
  )
}

let testSession = GoogleSession(
  cookies: ["SAPISID": "AbCdEf123456", "SID": "sid-value", "HSID": "hsid"],
  expiresAt: Date().addingTimeInterval(86_400)
)
