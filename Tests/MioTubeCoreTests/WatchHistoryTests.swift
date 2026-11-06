import Foundation
import Testing
@testable import MioTubeCore

@Suite struct WatchHistoryTests {
  @Test func signedOutAndExpiredSessionsDoNotRecordAnything() async throws {
    let spy = SpyTransport(body: Data())
    let signedOut = WatchHistoryRecorder(client: try makeClient(spy))
    await #expect(throws: MioTubeError.notSignedIn) { try await signedOut.record(videoID: "video", session: testSession) }
    var expired = testSession
    expired.expiresAt = .distantPast
    let recorder = WatchHistoryRecorder(client: try makeClient(spy, session: expired))
    await #expect(throws: MioTubeError.notSignedIn) { try await recorder.record(videoID: "video", session: expired) }
    #expect(spy.requests.isEmpty)
  }

  @Test func rejectsUntrustedAndMismatchedHistoryURLsBeforeAttachingCredentials() throws {
    let profile = try testCatalog().metadata
    for url in [
      "https://attacker.example/api/stats/playback?docid=video",
      "https://www.youtube.com.attacker.example/api/stats/playback?docid=video",
      "http://www.youtube.com/api/stats/playback?docid=video",
      "https://user:password@www.youtube.com/api/stats/playback?docid=video",
      "https://www.youtube.com:444/api/stats/playback?docid=video",
      "https://www.youtube.com/pagead/conversion?docid=video",
      "https://www.youtube.com/api/stats/playback?docid=another-video",
      "https://www.youtube.com/api/stats/playback",
      "https://www.youtube.com/api/stats/playback?docid=video&docid=other",
    ] {
      let player: JSONValue = ["playbackTracking": ["videostatsPlaybackUrl": ["baseUrl": .string(url)]]]
      #expect(throws: MioTubeError.self) {
        try WatchHistoryRecorder.makeRequest(
          player: player, videoID: "video", session: testSession,
          profile: profile, clientVersion: profile.clientVersion, nonce: "nonce"
        )
      }
    }
  }

  @Test func cachedTrackingParametersCannotOverrideTheNewPlaybackIdentity() throws {
    let player: JSONValue = ["playbackTracking": ["videostatsPlaybackUrl": [
      "baseUrl": "https://s.youtube.com/api/stats/playback?docid=video&cpn=stale&cpn=duplicate&c=visionos&vm=a%2Bb%3D"
    ]]]
    let profile = try testCatalog().metadata
    let request = try WatchHistoryRecorder.makeRequest(
      player: player, videoID: "video", session: testSession,
      profile: profile, clientVersion: profile.clientVersion, nonce: "new-playback", config: Self.config
    )
    let url = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    #expect(url.host == "www.youtube.com")
    #expect(url.queryItems?.filter { $0.name == "cpn" }.map(\.value) == ["new-playback"])
    #expect(url.queryItems?.filter { $0.name == "c" }.map(\.value) == ["WEB"])
    #expect(url.queryItems?.first { $0.name == "vm" }?.value == "a+b=")
    #expect(!request.retryable)
    #expect(request.method == .post)
    #expect(request.headers["Content-Type"] == "application/x-www-form-urlencoded")
    #expect(String(decoding: request.body ?? Data(), as: UTF8.self) == "session_token=a%2Bb%2Fc%3D")
  }

  @Test func missingTrackingDoesNotClaimHistoryWasUpdated() async throws {
    let spy = SpyTransport(body: Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.utf8))
    let recorder = WatchHistoryRecorder(client: try makeClient(spy, session: testSession))
    await #expect(throws: MioTubeError.self) { try await recorder.record(videoID: "video", session: testSession) }
    #expect(!spy.requests.contains { $0.url.path == "/api/stats/playback" })
  }

  @Test func expiredServerSessionCannotWriteAnonymousHistory() async throws {
    let spy = SpyTransport(body: Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}}}"#.utf8))
    let recorder = WatchHistoryRecorder(client: try makeClient(spy, session: testSession))
    await #expect(throws: MioTubeError.unauthorized) { try await recorder.record(videoID: "video", session: testSession) }
    #expect(!spy.requests.contains { $0.url.path == "/api/stats/playback" })
  }

  @Test func accountSwitchDuringMetadataFetchCancelsTheHistoryWrite() async throws {
    let session = InMemorySessionStore(testSession)
    let transport = SwitchingAccountTransport(session: session)
    let client = InnertubeClient(
      transport: transport, catalog: try testCatalog(), session: session, locale: .enUS
    )
    await #expect(throws: CancellationError.self) {
      try await WatchHistoryRecorder(client: client).record(videoID: "video", session: testSession)
    }
    #expect(await transport.historyWrites == 0)
  }

  @Test func serverRejectionIsReportedInsteadOfClaimingSuccess() async throws {
    for status in [401, 403] {
      let spy = SpyTransport { request in
        if request.url.path == "/" {
          return HTTPResponse(status: 200, data: Data(Self.bootstrap.utf8))
        }
        if request.url.path == "/api/stats/playback" {
          throw MioTubeError.http(status: status, body: "forbidden")
        }
        return HTTPResponse(status: 200, data: try Self.player.encoded())
      }
      let catalog = try testCatalog()
      let config = InnertubeConfigProvider(transport: spy, userAgent: catalog.metadata.httpUserAgent ?? "")
      let client = InnertubeClient(
        transport: spy, catalog: catalog, session: InMemorySessionStore(testSession), config: config, locale: .enUS
      )
      let recorder = WatchHistoryRecorder(client: client)
      let expected: MioTubeError = status == 401 ? .unauthorized : .http(status: status, body: "forbidden")
      await #expect(throws: expected) {
        try await recorder.record(videoID: "video", session: testSession)
      }
    }
  }

  @Test func queuedPlaybackCannotBeWrittenToAnAlreadyChangedAccount() async throws {
    let spy = SpyTransport(body: Data())
    let replacement = GoogleSession(
      cookies: ["SAPISID": "replacement-account"], expiresAt: Date().addingTimeInterval(3600)
    )
    let recorder = WatchHistoryRecorder(client: try makeClient(spy, session: replacement))
    await #expect(throws: CancellationError.self) {
      try await recorder.record(videoID: "video", session: testSession)
    }
    #expect(spy.requests.isEmpty)
  }

  @Test func missingSessionTokenDoesNotFallBackToAnUnboundHistoryWrite() throws {
    let profile = try testCatalog().metadata
    #expect(throws: MioTubeError.self) {
      try WatchHistoryRecorder.makeRequest(
        player: Self.player, videoID: "video", session: testSession, profile: profile,
        clientVersion: profile.clientVersion, nonce: "nonce"
      )
    }
  }

  @Test func historyUsesObservedPositionAndSelectedAccountRoutingWithoutInventingAFormat() throws {
    let profile = try testCatalog().metadata
    var session = testSession
    session.accountIndex = 2
    session.delegatedSessionID = "brand-channel"
    let request = try WatchHistoryRecorder.makeRequest(
      player: Self.player, videoID: "video", session: session, profile: profile,
      clientVersion: profile.clientVersion, nonce: "abcdefghijklmnop", position: 35.25, config: Self.config
    )
    let url = try #require(URLComponents(url: request.url, resolvingAgainstBaseURL: false))
    #expect(url.queryItems?.first { $0.name == "cmt" }?.value == "35.25")
    #expect(url.queryItems?.contains { $0.name == "fmt" } == false)
    #expect(request.headers["X-Goog-AuthUser"] == "2")
    #expect(request.headers["X-Goog-PageId"] == "brand-channel")
  }

  @Test func changingAccountRoutingWithoutChangingCookiesCancelsQueuedHistory() async throws {
    var replacement = testSession
    replacement.accountIndex = 1
    let spy = SpyTransport(body: Data())
    let recorder = WatchHistoryRecorder(client: try makeClient(spy, session: replacement))
    await #expect(throws: CancellationError.self) {
      try await recorder.record(videoID: "video", session: testSession)
    }
    #expect(spy.requests.isEmpty)
  }

  private static let config = InnertubeConfig(
    clientVersion: nil, visitorData: nil, fetchedAt: Date(), loggedIn: true, xsrfToken: "a+b/c="
  )

  private static let bootstrap = #"{"INNERTUBE_CLIENT_VERSION":"2.20261030.02.00","LOGGED_IN":true,"XSRF_TOKEN":"a+b/c="}"#

  fileprivate static let player: JSONValue = [
    "responseContext": ["mainAppWebResponseContext": ["loggedOut": false]],
    "playbackTracking": ["videostatsPlaybackUrl": [
      "baseUrl": "https://s.youtube.com/api/stats/playback?docid=video&vm=token"
    ]],
  ]
}

private actor SwitchingAccountTransport: HTTPTransport {
  let session: InMemorySessionStore
  private(set) var historyWrites = 0

  init(session: InMemorySessionStore) { self.session = session }

  func send(_ request: HTTPRequest) async throws -> HTTPResponse {
    if request.url.path == "/api/stats/playback" { historyWrites += 1 }
    await session.save(GoogleSession(
      cookies: ["SAPISID": "a-different-account"], expiresAt: Date().addingTimeInterval(3600)
    ))
    return HTTPResponse(status: 200, data: try WatchHistoryTests.player.encoded())
  }
}
