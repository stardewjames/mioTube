import Foundation

public struct InnertubeConfig: Sendable, Equatable {
  public var clientVersion: String?
  public var visitorData: String?
  public var fetchedAt: Date
  public var loggedIn: Bool?
  public var accountIndex: Int?
  public var delegatedSessionID: String?
  public var userSessionID: String?
  public var xsrfToken: String?

  public init(
    clientVersion: String?, visitorData: String?, fetchedAt: Date,
    loggedIn: Bool? = nil, accountIndex: Int? = nil,
    delegatedSessionID: String? = nil, userSessionID: String? = nil, xsrfToken: String? = nil
  ) {
    self.clientVersion = clientVersion
    self.visitorData = visitorData
    self.fetchedAt = fetchedAt
    self.loggedIn = loggedIn
    self.accountIndex = accountIndex
    self.delegatedSessionID = delegatedSessionID
    self.userSessionID = userSessionID
    self.xsrfToken = xsrfToken
  }

  /// Extracts `INNERTUBE_CLIENT_VERSION` and `VISITOR_DATA` from youtube.com HTML.
  public static func scrape(_ html: String, at date: Date = Date()) -> InnertubeConfig {
    let sync = firstCapture(in: html, key: "DATASYNC_ID")?.components(separatedBy: "||")
    let delegated = firstCapture(in: html, key: "DELEGATED_SESSION_ID")
      ?? (sync?.count == 2 && sync?[1].isEmpty == false ? sync?[0] : nil)
    let user = firstCapture(in: html, key: "USER_SESSION_ID")
      ?? (sync?.count == 2 ? (sync?[1].isEmpty == false ? sync?[1] : sync?[0]) : nil)
    return InnertubeConfig(
      clientVersion: firstCapture(in: html, key: "INNERTUBE_CLIENT_VERSION"),
      visitorData: firstCapture(in: html, key: "VISITOR_DATA"),
      fetchedAt: date,
      loggedIn: firstValue(in: html, key: "LOGGED_IN")?.bool,
      accountIndex: firstValue(in: html, key: "SESSION_INDEX")?.int,
      delegatedSessionID: delegated, userSessionID: user,
      xsrfToken: firstCapture(in: html, key: "XSRF_TOKEN")
    )
  }


  static func firstCapture(in html: String, key: String) -> String? {
    firstValue(in: html, key: key)?.string.flatMap { $0.isEmpty ? nil : $0 }
  }

  private static func firstValue(in html: String, key: String) -> JSONValue? {
    let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|true|false|-?[0-9]+)"
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
          let range = Range(match.range(at: 1), in: html)
    else { return nil }
    return try? JSONValue.decode(Data(html[range].utf8))
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
  private var scope: GoogleSession?
  private var flightID: UUID?

  public init(transport: any HTTPTransport, userAgent: String, ttl: TimeInterval = 24 * 3600) {
    self.transport = transport
    self.userAgent = userAgent
    self.ttl = ttl
  }

  public var current: InnertubeConfig? { cached }

  private var lastFailure: Date?
  static let failureBackoff: TimeInterval = 5 * 60

  public func config(session: GoogleSession? = nil) async -> InnertubeConfig? {
    let active = session.flatMap { $0.hasAuthCookie && $0.expiresAt > Date() ? $0 : nil }
    let sameScope = (scope == nil && active == nil)
      || (scope.flatMap { old in active.map { old.hasSameIdentity(as: $0) } } == true)
    if !sameScope {
      cached = nil
      lastFailure = nil
      inFlight = nil
      flightID = nil
      scope = active
    }
    if let cached, Date().timeIntervalSince(cached.fetchedAt) < ttl { return cached }
    if let lastFailure, Date().timeIntervalSince(lastFailure) < Self.failureBackoff { return cached }
    if let inFlight { return await inFlight.value }
    let transport = transport
    let userAgent = userAgent
    let id = UUID()
    let task = Task<InnertubeConfig?, Never> {
      var components = URLComponents(string: "https://www.youtube.com/")!
      components.queryItems = [URLQueryItem(name: "hl", value: "en")]
      if let index = active?.accountIndex {
        components.queryItems?.append(URLQueryItem(name: "authuser", value: String(index)))
      }
      var headers = ["User-Agent": userAgent, "Accept-Language": "en-US,en;q=0.9"]
      // Anonymous consent only; authenticated bootstrap uses exactly the selected session jar.
      headers["Cookie"] = active.map { CookieJar.headerValue($0.cookies) } ?? "SOCS=CAI"
      let request = HTTPRequest(url: components.url!, headers: headers, timeout: 15)
      guard let response = try? await transport.send(request) else { return nil }
      let config = InnertubeConfig.scrape(String(decoding: response.data, as: UTF8.self))
      return (config.clientVersion == nil && config.visitorData == nil) ? nil : config
    }
    inFlight = task
    flightID = id
    let result = await task.value
    guard flightID == id else { return result }
    inFlight = nil
    if let result { cached = result } else { lastFailure = Date() }
    return result ?? cached
  }

  /// Drops the cached value so the next `config()` refetches (Diagnostics "Re-probe").
  public func invalidate() {
    cached = nil
    lastFailure = nil
    inFlight?.cancel()
    inFlight = nil
    flightID = nil
  }

  /// Fallback when youtube.com could not be scraped: reuse the `responseContext.visitorData`
  /// InnerTube hands out. Without any visitor id, anonymous `player` calls hit the bot check.
  public func adopt(visitorData: String, session: GoogleSession? = nil) {
    let sameScope = (scope == nil && session == nil)
      || (scope.flatMap { old in session.map { old.hasSameIdentity(as: $0) } } == true)
    guard sameScope, !visitorData.isEmpty, cached?.visitorData == nil else { return }
    cached = InnertubeConfig(
      clientVersion: cached?.clientVersion, visitorData: visitorData, fetchedAt: cached?.fetchedAt ?? Date(),
      loggedIn: cached?.loggedIn, accountIndex: cached?.accountIndex,
      delegatedSessionID: cached?.delegatedSessionID, userSessionID: cached?.userSessionID,
      xsrfToken: cached?.xsrfToken
    )
  }
}
