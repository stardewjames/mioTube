import Foundation

public struct InnertubeLocale: Sendable, Hashable {
  public var hl: String
  public var gl: String
  public var timeZone: String
  public var utcOffsetMinutes: Int

  public init(hl: String, gl: String, timeZone: String, utcOffsetMinutes: Int) {
    self.hl = hl
    self.gl = gl
    self.timeZone = timeZone
    self.utcOffsetMinutes = utcOffsetMinutes
  }

  public static var current: InnertubeLocale {
    let locale = Locale.current
    let language = locale.language.languageCode?.identifier ?? "en"
    let region = locale.region?.identifier ?? "US"
    let zone = TimeZone.current
    return InnertubeLocale(
      hl: language, gl: region, timeZone: zone.identifier,
      utcOffsetMinutes: zone.secondsFromGMT() / 60
    )
  }

  public static let enUS = InnertubeLocale(hl: "en", gl: "US", timeZone: "UTC", utcOffsetMinutes: 0)
}

/// Single entry point for `POST /youtubei/v1/*`.
public actor InnertubeClient {
  public nonisolated let transport: any HTTPTransport
  public nonisolated let catalog: ProfileCatalog
  public nonisolated let session: any SessionProviding
  public nonisolated let config: InnertubeConfigProvider?
  public nonisolated let locale: InnertubeLocale

  public init(
    transport: any HTTPTransport,
    catalog: ProfileCatalog,
    session: any SessionProviding,
    config: InnertubeConfigProvider? = nil,
    locale: InnertubeLocale = .current
  ) {
    self.transport = transport
    self.catalog = catalog
    self.session = session
    self.config = config
    self.locale = locale
  }

  public func hasSession() async -> Bool {
    guard let current = await session.current() else { return false }
    return current.hasAuthCookie && current.expiresAt > Date()
  }

  /// Posts to the metadata profile.
  public func post(
    _ endpoint: String, _ body: JSONValue, authenticated: Bool = true, retryable: Bool = true,
    expectedSession: GoogleSession? = nil
  ) async throws -> JSONValue {
    try await post(
      endpoint, body, profileID: catalog.metadataProfile, authenticated: authenticated,
      retryable: retryable, expectedSession: expectedSession
    )
  }

  public func post(
    _ endpoint: String, _ body: JSONValue, profileID: String, authenticated: Bool = true,
    retryable: Bool = true, expectedSession: GoogleSession? = nil
  ) async throws -> JSONValue {
    guard let profile = catalog.profile(profileID) else {
      throw MioTubeError.invalidResponse("unknown client profile \(profileID)")
    }
    try Task.checkCancellation()
    let snapshot = authenticated && profile.supportsCookies ? await session.current() : nil
    let active = snapshot.flatMap { $0.hasAuthCookie && $0.expiresAt > Date() ? $0 : nil }
    if let expectedSession {
      guard let active, active.hasSameIdentity(as: expectedSession) else { throw CancellationError() }
    }
    let live = await config?.config(session: active)
    try Task.checkCancellation()
    if let active {
      guard let current = await session.current(), current.expiresAt > Date(),
            current.hasSameIdentity(as: active)
      else { throw CancellationError() }
    }
    let request = try Self.makeRequest(
      endpoint: endpoint, body: body, profile: profile, apiKey: catalog.apiKey, locale: locale,
      liveConfig: live, session: active, retryable: retryable
    )
    try Task.checkCancellation()
    let response: HTTPResponse
    do {
      response = try await transport.send(request)
    } catch MioTubeError.http(let status, _) where status == 401 {
      throw MioTubeError.unauthorized
    }
    try Task.checkCancellation()
    if let active {
      guard let current = await session.current(), current.expiresAt > Date(),
            current.hasSameIdentity(as: active)
      else { throw CancellationError() }
    }
    let json = try JSONValue.decode(response.data)
    guard json.object != nil else { throw MioTubeError.invalidResponse("InnerTube returned a non-object response") }
    if let error = json["error"], error != .null {
      if error["code"]?.int == 401 || error["status"]?.string == "UNAUTHENTICATED" {
        throw MioTubeError.unauthorized
      }
      let message = error["message"]?.string ?? error["status"]?.string ?? "Unknown API error"
      throw MioTubeError.invalidResponse("InnerTube \(endpoint): \(message)")
    }
    if live?.visitorData == nil, let visitor = json["responseContext", "visitorData"]?.string {
      await config?.adopt(visitorData: visitor, session: active)
    }
    if request.headers["Authorization"] != nil,
       json["responseContext", "mainAppWebResponseContext", "loggedOut"]?.bool == true {
      throw MioTubeError.unauthorized
    }
    return json
  }

  /// Builds the exact HTTP request; static so it can be unit-tested.
  public static func makeRequest(
    endpoint: String, body: JSONValue, profile: ClientProfile, apiKey: String, locale: InnertubeLocale,
    liveConfig: InnertubeConfig?, session: GoogleSession?, timestamp: Int = .init(Date().timeIntervalSince1970),
    retryable: Bool = true
  ) throws -> HTTPRequest {
    var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/\(endpoint)")!
    components.queryItems = [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "prettyPrint", value: "false")]

    // The scraped version belongs to the WEB client; other clients keep their pins.
    let clientVersion = (profile.clientName == "WEB" ? liveConfig?.clientVersion : nil) ?? profile.clientVersion

    guard let object = body.object else {
      throw MioTubeError.invalidResponse("InnerTube request body must be an object")
    }
    let session = session.flatMap {
      profile.supportsCookies && $0.hasAuthCookie && $0.expiresAt > Date() ? $0 : nil
    }
    var payload = object
    var context = payload["context"]?.object ?? [:]
    var client = context["client"]?.object ?? [:]
    for (key, value) in profile.extraContext ?? [:] { client[key] = value }
    let identity: [String: JSONValue] = [
      "clientName": .string(profile.clientName),
      "clientVersion": .string(clientVersion),
      "hl": .string(locale.hl),
      "gl": .string(locale.gl),
      "timeZone": .string(locale.timeZone),
      "utcOffsetMinutes": .number(Double(locale.utcOffsetMinutes)),
    ]
    // Identity fields are authoritative; endpoint-specific client/user context survives.
    for (key, value) in identity { client[key] = value }
    if let ua = profile.userAgent { client["userAgent"] = .string(ua) }
    if let visitor = liveConfig?.visitorData { client["visitorData"] = .string(visitor) }
    context["client"] = .object(client)
    var user = context["user"]?.object ?? [:]
    if user["lockedSafetyMode"] == nil { user["lockedSafetyMode"] = false }
    let delegatedID = session.flatMap { $0.delegatedSessionID ?? liveConfig?.delegatedSessionID }
    if let delegatedID { user["onBehalfOfUser"] = .string(delegatedID) }
    else { user.removeValue(forKey: "onBehalfOfUser") }
    context["user"] = .object(user)
    payload["context"] = .object(context)

    var headers: [String: String] = [
      "Content-Type": "application/json",
      "X-YouTube-Client-Name": String(profile.clientNameHeader),
      "X-YouTube-Client-Version": clientVersion,
      "Origin": "https://www.youtube.com",
      "Referer": "https://www.youtube.com/",
      "Accept-Language": locale.hl,
    ]
    if let ua = profile.httpUserAgent { headers["User-Agent"] = ua }
    if let visitor = client["visitorData"]?.string { headers["X-Goog-Visitor-Id"] = visitor }
    if profile.supportsCookies, let loggedIn = liveConfig?.loggedIn, session != nil || !loggedIn {
      headers["X-Youtube-Bootstrap-Logged-In"] = loggedIn ? "true" : "false"
    }
    if let session, let auth = SapisidAuth.header(
      cookies: session.cookies, timestamp: timestamp,
      userSessionID: session.userSessionID ?? liveConfig?.userSessionID
    ) {
      headers["Cookie"] = CookieJar.headerValue(session.cookies)
      headers["Authorization"] = auth
      if let index = session.accountIndex ?? liveConfig?.accountIndex {
        headers["X-Goog-AuthUser"] = String(index)
      }
      if let delegatedID { headers["X-Goog-PageId"] = delegatedID }
      headers["X-Origin"] = "https://www.youtube.com"
    }

    return HTTPRequest(
      method: .post, url: components.url!, headers: headers,
      body: try JSONValue.object(payload).encoded(), timeout: 20, retryable: retryable
    )
  }
}
