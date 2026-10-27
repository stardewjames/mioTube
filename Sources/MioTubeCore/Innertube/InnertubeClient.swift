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
    await session.current()?.hasAuthCookie == true
  }

  /// Posts to the metadata profile.
  public func post(_ endpoint: String, _ body: JSONValue, authenticated: Bool = true) async throws -> JSONValue {
    try await post(endpoint, body, profileID: catalog.metadataProfile, authenticated: authenticated)
  }

  public func post(
    _ endpoint: String, _ body: JSONValue, profileID: String, authenticated: Bool = true
  ) async throws -> JSONValue {
    guard let profile = catalog.profile(profileID) else {
      throw MioTubeError.invalidResponse("unknown client profile \(profileID)")
    }
    let live = await config?.config()
    let session = authenticated && profile.supportsCookies ? await session.current() : nil
    let request = try Self.makeRequest(
      endpoint: endpoint, body: body, profile: profile, apiKey: catalog.apiKey, locale: locale,
      liveConfig: live, session: session?.hasAuthCookie == true ? session : nil
    )
    let response = try await transport.send(request)
    let json = try JSONValue.decode(response.data)
    if live?.visitorData == nil, let visitor = json["responseContext", "visitorData"]?.string {
      await config?.adopt(visitorData: visitor)
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
    liveConfig: InnertubeConfig?, session: GoogleSession?, timestamp: Int = .init(Date().timeIntervalSince1970)
  ) throws -> HTTPRequest {
    var components = URLComponents(string: "https://www.youtube.com/youtubei/v1/\(endpoint)")!
    components.queryItems = [URLQueryItem(name: "key", value: apiKey), URLQueryItem(name: "prettyPrint", value: "false")]

    // The scraped version belongs to the WEB client; other clients keep their pins.
    let clientVersion = (profile.clientName == "WEB" ? liveConfig?.clientVersion : nil) ?? profile.clientVersion

    var client: [String: JSONValue] = [
      "clientName": .string(profile.clientName),
      "clientVersion": .string(clientVersion),
      "hl": .string(locale.hl),
      "gl": .string(locale.gl),
      "timeZone": .string(locale.timeZone),
      "utcOffsetMinutes": .number(Double(locale.utcOffsetMinutes)),
    ]
    if let visitor = liveConfig?.visitorData { client["visitorData"] = .string(visitor) }
    for (key, value) in profile.extraContext ?? [:] { client[key] = value }

    var payload: [String: JSONValue] = body.object ?? [:]
    var context = payload["context"]?.object ?? [:]
    context["client"] = .object(client)
    context["user"] = ["lockedSafetyMode": false]
    payload["context"] = .object(context)

    var headers: [String: String] = [
      "Content-Type": "application/json",
      "X-YouTube-Client-Name": String(profile.clientNameHeader),
      "X-YouTube-Client-Version": clientVersion,
      "Origin": "https://www.youtube.com",
      "X-Goog-Api-Format-Version": "2",
      "Accept-Language": locale.hl,
    ]
    if let ua = profile.userAgent { headers["User-Agent"] = ua }
    if let visitor = liveConfig?.visitorData { headers["X-Goog-Visitor-Id"] = visitor }
    if let session, let auth = SapisidAuth.header(cookies: session.cookies, timestamp: timestamp) {
      headers["Cookie"] = CookieJar.headerValue(session.cookies)
      headers["Authorization"] = auth
      headers["X-Goog-AuthUser"] = "0"
      headers["X-Origin"] = "https://www.youtube.com"
    }

    return HTTPRequest(
      method: .post, url: components.url!, headers: headers,
      body: try JSONValue.object(payload).encoded(), timeout: 20
    )
  }
}
