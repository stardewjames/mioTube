import Foundation
import Testing
@testable import MioTubeCore

@Suite struct AuthContractTests {
  @Test func partitionedOnlySecretsAndUserBinding() {
    #expect(SapisidAuth.header(cookies: ["__Secure-1PAPISID": "AbCdEf123456"], timestamp: 1_750_000_000)
      == "SAPISID1PHASH 1750000000_0117d5fe874c62e4fcec81195dde8fc46d6bdfab")
    #expect(SapisidAuth.header(cookies: ["SAPISID": "AbCdEf123456"], timestamp: 1_750_000_000,
      userSessionID: "user-session") == "SAPISIDHASH 1750000000_bff8f0cef5631c1d80990b8474adfe19ab579c60_u")
    #expect(SapisidAuth.header(cookies: ["SAPISID": "AbCdEf123456"], origin: "https://m.youtube.com",
      timestamp: 1_750_000_000) == "SAPISIDHASH 1750000000_1f0d4e6732ebcd35cef2501fff6ad98c9c552a0c")
    #expect(SapisidAuth.header(cookies: ["SAPISID": "", "__Secure-3PAPISID": ""]) == nil)
    #expect(GoogleSession(cookies: ["__Secure-1PAPISID": "secret"], expiresAt: .distantFuture).hasAuthCookie)
  }

  @Test func endpointContextSurvivesWithoutOverridingIdentity() throws {
    let catalog = try testCatalog()
    let request = try InnertubeClient.makeRequest(
      endpoint: "player", body: ["context": [
        "client": ["clientName": "ANDROID", "clientVersion": "wrong", "visitorData": "caller",
          "originalUrl": "https://www.youtube.com/watch?v=video"],
        "user": ["lockedSafetyMode": true, "enableSafetyMode": true],
        "thirdParty": ["embedUrl": "https://example.org/"],
        "request": ["useSsl": true],
      ]], profile: catalog.metadata, apiKey: catalog.apiKey, locale: .enUS,
      liveConfig: InnertubeConfig(clientVersion: "2.99", visitorData: "bootstrap", fetchedAt: Date()), session: nil
    )
    let body = try #require(request.jsonBody)
    #expect(body["context", "client", "clientName"]?.string == catalog.metadata.clientName)
    #expect(body["context", "client", "clientVersion"] == "2.99")
    #expect(body["context", "client", "originalUrl"] == "https://www.youtube.com/watch?v=video")
    #expect(body["context", "client", "visitorData"] == "bootstrap")
    #expect(request.headers["X-Goog-Visitor-Id"] == "bootstrap")
    #expect(body["context", "user", "lockedSafetyMode"] == true)
    #expect(body["context", "user", "enableSafetyMode"] == true)
    #expect(body["context", "thirdParty", "embedUrl"] == "https://example.org/")
    #expect(body["context", "request", "useSsl"] == true)
  }

  @Test func browserUserAgentSeparatesContextAndHTTPWire() throws {
    let profile = ClientProfile(id: "browser", clientName: "WEB", clientVersion: "2.1",
      clientNameHeader: 1, userAgent: "Browser/1,gzip(gfe)", supportsCookies: true,
      supportsHLS: false, requiresJSPlayer: true)
    let request = try InnertubeClient.makeRequest(endpoint: "browse", body: [:], profile: profile,
      apiKey: "key", locale: .enUS, liveConfig: nil, session: nil)
    #expect(request.headers["User-Agent"] == "Browser/1")
    #expect(request.jsonBody?["context", "client", "userAgent"] == "Browser/1,gzip(gfe)")
  }

  @Test func directBuilderCannotLeakUnsupportedOrExpiredCredentials() throws {
    let catalog = try testCatalog()
    let unsupported = try #require(catalog.profiles.first { !$0.supportsCookies })
    let live = InnertubeConfig(clientVersion: nil, visitorData: nil, fetchedAt: Date(),
      loggedIn: true, accountIndex: 3, delegatedSessionID: "channel", userSessionID: "user")
    for (profile, session) in [(unsupported, testSession), (catalog.metadata,
      GoogleSession(cookies: testSession.cookies, expiresAt: .distantPast))] {
      let request = try InnertubeClient.makeRequest(endpoint: "player", body: ["context": [
        "user": ["onBehalfOfUser": "untrusted-channel"]]], profile: profile,
        apiKey: catalog.apiKey, locale: .enUS, liveConfig: live, session: session)
      #expect(request.headers["Cookie"] == nil)
      #expect(request.headers["Authorization"] == nil)
      #expect(request.headers["X-Goog-AuthUser"] == nil)
      #expect(request.headers["X-Goog-PageId"] == nil)
      #expect(request.headers["X-Youtube-Bootstrap-Logged-In"] == nil)
      #expect(request.jsonBody?["context", "user", "onBehalfOfUser"] == nil)
    }
  }

  @Test func authenticatedBootstrapRoutesTheSelectedAccount() async throws {
    var selected = testSession
    selected.accountIndex = 2
    let spy = SpyTransport { request in
      if request.url.path == "/" {
        return HTTPResponse(status: 200, data: Data(#"{"INNERTUBE_CLIENT_VERSION":"2.99","VISITOR_DATA":"account-visitor","SESSION_INDEX":2,"LOGGED_IN":true,"DATASYNC_ID":"channel||user","XSRF_TOKEN":"token\u003d"}"#.utf8))
      }
      return HTTPResponse(status: 200, data: Data("{}".utf8))
    }
    let provider = InnertubeConfigProvider(transport: spy, userAgent: "UA")
    let client = InnertubeClient(transport: spy, catalog: try testCatalog(),
      session: InMemorySessionStore(selected), config: provider, locale: .enUS)
    _ = try await client.post("browse", ["browseId": "FElibrary"])
    let bootstrap = try #require(spy.requests.first)
    #expect(bootstrap.url.query?.contains("authuser=2") == true)
    #expect(bootstrap.headers["Cookie"]?.contains("SAPISID=AbCdEf123456") == true)
    let request = try #require(spy.requests.last)
    #expect(request.headers["X-Goog-AuthUser"] == "2")
    #expect(request.headers["X-Goog-PageId"] == "channel")
    #expect(request.headers["X-Youtube-Bootstrap-Logged-In"] == "true")
    #expect(request.headers["Authorization"]?.hasSuffix("_u") == true)
    #expect(request.headers["X-Goog-Visitor-Id"] == "account-visitor")
    #expect(request.jsonBody?["context", "user", "onBehalfOfUser"] == "channel")
    let config = await provider.current
    #expect(config?.xsrfToken == "token=")
  }

  @Test func bootstrapCacheDoesNotCrossAccountsOrAnonymousRequests() async throws {
    let spy = SpyTransport { request in
      let value = request.headers["Cookie"]?.contains("SAPISID=first") == true ? "first" :
        request.headers["Cookie"]?.contains("SAPISID=second") == true ? "second" : "anonymous"
      return HTTPResponse(status: 200, data: Data("{\"VISITOR_DATA\":\"\(value)\"}".utf8))
    }
    let provider = InnertubeConfigProvider(transport: spy, userAgent: "UA")
    let first = GoogleSession(cookies: ["SAPISID": "first"], expiresAt: .distantFuture)
    let second = GoogleSession(cookies: ["SAPISID": "second"], expiresAt: .distantFuture)
    #expect(await provider.config(session: first)?.visitorData == "first")
    #expect(await provider.config(session: second)?.visitorData == "second")
    #expect(await provider.config()?.visitorData == "anonymous")
    #expect(spy.requests.last?.headers["Cookie"]?.contains("SAPISID") == false)
  }

  @Test func accountSwitchDuringBootstrapCancelsBeforeTheEndpoint() async throws {
    let store = InMemorySessionStore(testSession)
    let transport = SwitchingBootstrapTransport(store: store)
    let client = InnertubeClient(transport: transport, catalog: try testCatalog(), session: store,
      config: InnertubeConfigProvider(transport: transport, userAgent: "UA"), locale: .enUS)
    await #expect(throws: CancellationError.self) {
      _ = try await client.post("like/like", ["target": ["videoId": "video"]], retryable: false,
        expectedSession: testSession)
    }
    #expect(await transport.endpointCalls == 0)
  }

  @Test func metadataRefreshDoesNotChangeAccountIdentity() {
    var refreshed = testSession
    refreshed.name = "New display name"
    refreshed.avatarURL = URL(string: "https://example.org/avatar")
    refreshed.expiresAt = .distantFuture
    #expect(refreshed.hasSameIdentity(as: testSession))
    refreshed.accountIndex = 1
    #expect(!refreshed.hasSameIdentity(as: testSession))
  }

  @Test func savedSessionsWithoutRoutingFieldsStillDecode() throws {
    let session = try JSONDecoder().decode(GoogleSession.self,
      from: Data(#"{"cookies":{"SAPISID":"secret"},"expiresAt":0}"#.utf8))
    #expect(session.cookies["SAPISID"] == "secret")
    #expect(session.accountIndex == nil)
    #expect(session.delegatedSessionID == nil)
    #expect(session.userSessionID == nil)
  }

  @Test func successfulHTTPStatusDoesNotHideAPIError() async throws {
    let spy = SpyTransport(body: Data(#"{"error":{"code":400,"status":"INVALID_ARGUMENT","message":"Bad continuation"}}"#.utf8))
    let client = try makeClient(spy)
    await #expect(throws: MioTubeError.invalidResponse("InnerTube browse: Bad continuation")) {
      _ = try await client.post("browse", ["continuation": "bad"])
    }
    let unauthorized = try makeClient(SpyTransport(body: Data(#"{"error":{"code":401,"status":"UNAUTHENTICATED"}}"#.utf8)))
    await #expect(throws: MioTubeError.unauthorized) { _ = try await unauthorized.post("browse", [:]) }
    let malformed = try makeClient(SpyTransport(body: Data("[]".utf8)))
    await #expect(throws: MioTubeError.invalidResponse("InnerTube returned a non-object response")) {
      _ = try await malformed.post("browse", [:])
    }
  }

  @Test func cancelledCallerDoesNotStartNetworkRequests() async throws {
    let spy = SpyTransport(body: Data("{}".utf8))
    let client = try makeClient(spy)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await client.post("browse", [:])
    }
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(spy.requests.isEmpty)
  }

  @Test func httpAuthenticationFailureReachesSessionExpiryHandling() async throws {
    let spy = SpyTransport(status: 401, body: Data(#"{"error":{"status":"UNAUTHENTICATED"}}"#.utf8))
    let client = try makeClient(spy, session: testSession)
    await #expect(throws: MioTubeError.unauthorized) {
      _ = try await client.post("browse", ["browseId": "FEhistory"])
    }
  }

  @Test func importedCookieDomainsCannotImpersonateYouTubeOrMixGoogleTracking() {
    let parsed = CookieJar.parse("""
    .evilyoutube.com\tTRUE\t/\tTRUE\t1900000000\tSAPISID\tattacker
    .notgoogle.com\tTRUE\t/\tTRUE\t1900000000\tSID\tattacker
    .google.com\tTRUE\t/\tTRUE\t1700000000\tSAPISID\tgoogle-copy
    .google.com\tTRUE\t/\tTRUE\t1900000000\tGOOGLE_ONLY\tprivate
    accounts.youtube.com\tFALSE\t/\tTRUE\t1900000000\tHOST_ONLY\tprivate
    .youtube.com\tTRUE\t/other\tTRUE\t1900000000\tPATH_ONLY\tprivate
    .youtube.com\tTRUE\t/\tTRUE\t2000000000\tSAPISID\tyoutube-copy
    """)
    #expect(parsed.cookies == ["SAPISID": "youtube-copy"])
    #expect(parsed.earliestExpiry == Date(timeIntervalSince1970: 2_000_000_000))
    #expect(GoogleSession.matchesDomain(".youtube.com", root: "youtube.com"))
    #expect(!GoogleSession.matchesDomain("evilyoutube.com", root: "youtube.com"))
    #expect(!GoogleSession.matchesDomain("youtube.com.attacker.test", root: "youtube.com"))
  }
}

private actor SwitchingBootstrapTransport: HTTPTransport {
  let store: InMemorySessionStore
  var endpointCalls = 0

  init(store: InMemorySessionStore) { self.store = store }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    if request.url.path == "/" {
      await store.save(GoogleSession(cookies: ["SAPISID": "replacement"], expiresAt: .distantFuture))
      return HTTPResponse(status: 200, data: Data(#"{"VISITOR_DATA":"old-account"}"#.utf8))
    }
    endpointCalls += 1
    return HTTPResponse(status: 200, data: Data("{}".utf8))
  }
}

extension AuthContractTests {
  @Test func authenticatedResponseCannotOutliveItsIssuingAccount() async throws {
    let store = InMemorySessionStore(testSession)
    let client = InnertubeClient(
      transport: SwitchingResponseTransport(store: store), catalog: try testCatalog(), session: store, locale: .enUS
    )
    await #expect(throws: CancellationError.self) {
      _ = try await client.post(
        "like/like", ["target": ["videoId": "video"]], retryable: false, expectedSession: testSession
      )
    }
  }
}

private actor SwitchingResponseTransport: HTTPTransport {
  let store: InMemorySessionStore

  init(store: InMemorySessionStore) { self.store = store }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    await store.save(GoogleSession(cookies: ["SAPISID": "replacement"], expiresAt: .distantFuture))
    return HTTPResponse(
      status: 200,
      data: Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}},"status":"STATUS_SUCCEEDED"}"#.utf8)
    )
  }
}
