import Foundation
import Testing
@testable import MioTubeCore

@Suite struct SapisidTests {
  @Test func headerMatchesKnownVector() {
    #expect(
      SapisidAuth.header(cookies: ["SAPISID": "AbCdEf123456"], timestamp: 1_750_000_000)
        == "SAPISIDHASH 1750000000_0117d5fe874c62e4fcec81195dde8fc46d6bdfab"
    )
  }

  @Test func secure3PCookieIsFallback() {
    let a = SapisidAuth.header(cookies: ["__Secure-3PAPISID": "AbCdEf123456"], timestamp: 1_750_000_000)
    #expect(a == "SAPISIDHASH 1750000000_0117d5fe874c62e4fcec81195dde8fc46d6bdfab")
  }

  @Test func noSecretNoHeader() {
    #expect(SapisidAuth.header(cookies: ["SID": "x"]) == nil)
  }

  @Test func appendsPartitionedVariants() throws {
    let header = try #require(SapisidAuth.header(
      cookies: ["SAPISID": "a", "__Secure-1PAPISID": "b", "__Secure-3PAPISID": "c"], timestamp: 1
    ))
    let schemes = header.split(separator: " ").enumerated().filter { $0.offset % 2 == 0 }.map { String($0.element) }
    #expect(schemes == ["SAPISIDHASH", "SAPISID1PHASH", "SAPISID3PHASH"])
  }
}

@Suite struct JSONValueTests {
  @Test func pathLookupOnFixture() throws {
    let json = try Fixture.json("watch_next.json")
    let title = json[
      "contents", "twoColumnWatchNextResults", "results", "results", "contents", "0",
      "videoPrimaryInfoRenderer", "title",
    ]?.text
    #expect(title?.contains("Never Gonna Give You Up") == true)
  }

  @Test func scalarsKeepTheirTypes() throws {
    let json = try JSONValue.decode(Data(#"{"b":true,"n":1,"f":1.5,"s":"x","z":null,"a":[1,"2"]}"#.utf8))
    #expect(json["b"] == .bool(true))
    #expect(json["n"]?.int == 1)
    #expect(json["f"]?.double == 1.5)
    #expect(json["z"] == .null)
    #expect(json["a", "1"]?.int == 2)
  }

  @Test func integersEncodeWithoutFraction() throws {
    let data = try JSONValue.object(["utcOffsetMinutes": -240, "x": 1.5]).encoded()
    #expect(String(decoding: data, as: UTF8.self) == #"{"utcOffsetMinutes":-240,"x":1.5}"#)
  }

  @Test func removeNestedPath() {
    var json: JSONValue = ["a": ["b": 1, "c": 2], "list": [1, 2, 3]]
    json.remove("a", "b")
    json.remove("list", "0")
    json.remove("missing", "x")
    #expect(json == ["a": ["c": 2], "list": [2, 3]])
  }

  @Test func parserHandlesEscapesAndSurrogates() throws {
    let json = try JSONValue.decode(Data(#"{"s":"a\"b\\c\/d\n\u00e9\ud83d\ude00","e":-1.5e3,"x":[]}"#.utf8))
    #expect(json["s"]?.string == "a\"b\\c/d\né😀")
    #expect(json["e"]?.double == -1500)
    #expect(json["x"] == .array([]))
  }

  @Test func parserRejectsTrailingGarbage() {
    #expect(throws: MioTubeError.self) { try JSONValue.decode(Data(#"{"a":1} x"#.utf8)) }
    #expect(throws: MioTubeError.self) { try JSONValue.decode(Data()) }
  }

  @Test func thumbnailPicksWidestAndFixesSchemeRelative() {
    let v: JSONValue = ["thumbnails": [["url": "//a/small", "width": 88], ["url": "//a/big", "width": 800], ["url": "//a/mid", "width": 176]]]
    #expect(v.firstThumbnailURL()?.absoluteString == "https://a/big")
  }
}

@Suite struct ClientTests {
  @Test func bundledCatalogDecodes() throws {
    let catalog = try testCatalog()
    // The cookie-less Apple client goes first: authenticated web clients return streams that
    // need the JS player / PO tokens and fail in AVPlayer.
    #expect(catalog.playbackOrder.first == "visionos")
    #expect(catalog.profile("visionos")?.supportsCookies == false)
    #expect(catalog.metadata.clientName == "WEB")
    for id in catalog.playbackOrder { #expect(catalog.profile(id) != nil) }
    #expect(catalog.profile("visionos")?.extraContext?["deviceModel"] == "RealityDevice17,1")
  }

  @Test func requestCarriesContextAndHeaders() throws {
    let catalog = try testCatalog()
    let profile = try #require(catalog.profile("visionos"))
    let request = try InnertubeClient.makeRequest(
      endpoint: "player", body: ["videoId": "abc"], profile: profile, apiKey: catalog.apiKey, locale: .enUS,
      liveConfig: InnertubeConfig(clientVersion: "2.99", visitorData: "VD", fetchedAt: Date()), session: nil
    )
    #expect(request.url.absoluteString == "https://www.youtube.com/youtubei/v1/player?key=\(catalog.apiKey)&prettyPrint=false")
    #expect(request.headers["X-YouTube-Client-Name"] == "101")
    // Live WEB version must not leak into other clients.
    #expect(request.headers["X-YouTube-Client-Version"] == "1.02")
    #expect(request.headers["X-Goog-Visitor-Id"] == "VD")
    #expect(request.headers["X-Youtube-Bootstrap-Logged-In"] == "false")
    #expect(request.headers["Authorization"] == nil)
    let body = try #require(request.jsonBody)
    #expect(body["videoId"] == "abc")
    #expect(body["context", "client", "osName"] == "visionOS")
    #expect(body["context", "client", "userAgent"]?.string == profile.userAgent)
    #expect(body["context", "user", "lockedSafetyMode"] == .bool(false))
  }

  @Test func liveVersionOverridesWebPin() throws {
    let catalog = try testCatalog()
    let request = try InnertubeClient.makeRequest(
      endpoint: "browse", body: [:], profile: catalog.metadata, apiKey: catalog.apiKey, locale: .enUS,
      liveConfig: InnertubeConfig(clientVersion: "2.20261026.01.00", visitorData: nil, fetchedAt: Date()),
      session: nil
    )
    #expect(request.jsonBody?["context", "client", "clientVersion"] == "2.20261026.01.00")
  }

  @Test func signedInRequestIsAuthorized() async throws {
    let spy = SpyTransport(body: Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.utf8))
    let client = try makeClient(spy, session: testSession)
    _ = try await client.post("browse", ["browseId": "FEwhat_to_watch"])
    let headers = try #require(spy.requests.first?.headers)
    #expect(headers["Authorization"]?.hasPrefix("SAPISIDHASH ") == true)
    #expect(headers["Cookie"] == "HSID=hsid; SAPISID=AbCdEf123456; SID=sid-value")
    #expect(headers["X-Goog-AuthUser"] == "0")
    #expect(headers["X-Youtube-Bootstrap-Logged-In"] == "true")
  }

  @Test func cookielessProfileNeverGetsCookies() async throws {
    let spy = SpyTransport(body: Data("{}".utf8))
    let client = try makeClient(spy, session: testSession)
    _ = try await client.post("player", ["videoId": "x"], profileID: "visionos")
    #expect(spy.requests.first?.headers["Cookie"] == nil)
    #expect(spy.requests.first?.headers["Authorization"] == nil)
  }

  @Test func loggedOutResponseWithSessionIsUnauthorized() async throws {
    let spy = SpyTransport(body: try Fixture.data("home.json"))
    let client = try makeClient(spy, session: testSession)
    await #expect(throws: MioTubeError.unauthorized) {
      _ = try await client.post("browse", ["browseId": "FEwhat_to_watch"])
    }
  }

  @Test func signedOutSendsNoAuthorization() async throws {
    let spy = SpyTransport(body: try Fixture.data("home.json"))
    let client = try makeClient(spy)
    _ = try await client.post("browse", ["browseId": "FEwhat_to_watch"])
    #expect(spy.requests.first?.headers["Authorization"] == nil)
    #expect(spy.requests.first?.headers["Cookie"] == nil)
  }
}

@Suite struct ConfigAndCookieTests {
  @Test func scrapesVersionAndVisitor() {
    let html = #"ytcfg.set({"INNERTUBE_CLIENT_VERSION":"2.20261026.01.00","x":1,"VISITOR_DATA":"CgtABC%3D%3D"});"#
    let config = InnertubeConfig.scrape(html)
    #expect(config.clientVersion == "2.20261026.01.00")
    #expect(config.visitorData == "CgtABC%3D%3D")
  }

  @Test func canaryVersionSuffixIsStripped() {
    let html = #""INNERTUBE_CLIENT_VERSION":"2.20261027.01.00-canary_experiment_2.20261026.01.00""#
    #expect(InnertubeConfig.scrape(html).clientVersion == "2.20261027.01.00")
    #expect(InnertubeConfig.scrape(#""INNERTUBE_CLIENT_VERSION":"garbage""#).clientVersion == nil)
  }

  @Test func adoptsResponseVisitorDataWhenScrapeFails() async throws {
    let spy = SpyTransport { request in
      if request.url.path == "/" { throw MioTubeError.http(status: 503, body: "") }
      return HTTPResponse(status: 200, data: Data(#"{"responseContext":{"visitorData":"VD123"}}"#.utf8))
    }
    let provider = InnertubeConfigProvider(transport: spy, userAgent: "UA")
    let client = InnertubeClient(
      transport: spy, catalog: try testCatalog(), session: InMemorySessionStore(), config: provider, locale: .enUS
    )
    _ = try await client.post("browse", ["browseId": "FEwhat_to_watch"])
    _ = try await client.post("player", ["videoId": "x"], profileID: "visionos")
    let player = try #require(spy.requests.last)
    #expect(player.headers["X-Goog-Visitor-Id"] == "VD123")
    #expect(player.jsonBody?["context", "client", "visitorData"] == "VD123")
    // The failed scrape is not retried on every request.
    #expect(spy.requests.filter { $0.url.path == "/" }.count == 1)
  }

  @Test func providerIsSingleFlightAndCached() async {
    let spy = SpyTransport { _ in
      HTTPResponse(status: 200, data: Data(#""INNERTUBE_CLIENT_VERSION":"2.1""#.utf8))
    }
    let provider = InnertubeConfigProvider(transport: spy, userAgent: "UA")
    async let a = provider.config()
    async let b = provider.config()
    let (ra, rb) = await (a, b)
    _ = await provider.config()
    #expect(ra?.clientVersion == "2.1" && rb?.clientVersion == "2.1")
    #expect(spy.requests.count == 1)
  }

  @Test func parsesCookieHeader() {
    let parsed = CookieJar.parse("Cookie: SAPISID=abc; SID=def==; empty=")
    #expect(parsed.cookies == ["SAPISID": "abc", "SID": "def==", "empty": ""])
  }

  @Test func parsesNetscapeFileKeepingYouTubeRows() {
    let file = """
    # Netscape HTTP Cookie File
    .youtube.com\tTRUE\t/\tTRUE\t1800000000\tSAPISID\tyt-value
    .google.com\tTRUE\t/\tTRUE\t1790000000\tSAPISID\tgoogle-value
    #HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t1810000000\tSID\tsid
    .example.com\tTRUE\t/\tTRUE\t1700000000\tOTHER\tx
    """
    let parsed = CookieJar.parse(file)
    #expect(parsed.cookies == ["SAPISID": "yt-value", "SID": "sid"])
    #expect(parsed.earliestExpiry == Date(timeIntervalSince1970: 1_790_000_000))
  }

  @Test func nonAuthCookieExpiryDoesNotAgeOutTheSession() {
    let file = """
    .youtube.com\tTRUE\t/\tTRUE\t1700000000\tVISITOR_INFO1_LIVE\tv
    .youtube.com\tTRUE\t/\tTRUE\t1900000000\tSAPISID\tyt-value
    """
    let parsed = CookieJar.parse(file)
    #expect(parsed.earliestExpiry == Date(timeIntervalSince1970: 1_900_000_000))
  }

  @Test func retryPolicyHonoursRetryAfterAndStops() {
    let policy = RetryPolicy(delays: [0.5, 1.5, 4], maxJitter: 0, maxRetryAfter: 30)
    #expect(policy.delay(forRetry: 0, retryAfterHeader: nil) == 0.5)
    #expect(policy.delay(forRetry: 2, retryAfterHeader: nil) == 4)
    #expect(policy.delay(forRetry: 3, retryAfterHeader: nil) == nil)
    #expect(policy.delay(forRetry: 1, retryAfterHeader: "7") == 7)
    #expect(policy.delay(forRetry: 1, retryAfterHeader: "900") == 30)
  }
}
