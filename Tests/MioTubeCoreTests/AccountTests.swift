import Foundation
import Testing
@testable import MioTubeCore

@Suite struct AccountActionsTests {
  static let ok = Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.utf8)

  @Test func ratingsPreserveOpaqueParamsAndDoNotReplayWrites() async throws {
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    try await actions.setLike(.like, videoID: "v1", params: "LIKE%3D")
    try await actions.setLike(.dislike, videoID: "v1", params: "DISLIKE%3D")
    try await actions.setLike(.none, videoID: "v1", params: "REMOVE%3D")
    #expect(spy.requests.map(\.url.path) == ["/youtubei/v1/like/like", "/youtubei/v1/like/dislike", "/youtubei/v1/like/removelike"])
    #expect(spy.requests.map { $0.jsonBody?["params"]?.string } == ["LIKE%3D", "DISLIKE%3D", "REMOVE%3D"])
    #expect(spy.requests.allSatisfy { $0.jsonBody?["target", "videoId"] == "v1" && $0.headers["Authorization"] != nil && !$0.retryable })
  }

  @Test func subscriptionUsesMatchingParamsAndRejectsUnchangedResponse() async throws {
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    try await actions.setSubscribed(true, channelID: "UC1", params: "SUB%3D")
    try await actions.setSubscribed(false, channelID: "UC1", params: "UNSUB%3D")
    #expect(spy.requests[0].url.path == "/youtubei/v1/subscription/subscribe")
    #expect(spy.requests[1].url.path == "/youtubei/v1/subscription/unsubscribe")
    #expect(spy.requests[1].jsonBody?["params"] == "UNSUB%3D")
    let rejected = SpyTransport(body: Data(#"{"actions":[{"updateSubscribeButtonAction":{"channelId":"UC1","subscribed":false}}]}"#.utf8))
    let rejectedActions = AccountActions(client: try makeClient(rejected, session: testSession))
    await #expect(throws: MioTubeError.self) { try await rejectedActions.setSubscribed(true, channelID: "UC1", params: "SUB") }
  }

  @Test func writesRequireSession() async throws {
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy))
    await #expect(throws: MioTubeError.notSignedIn) { try await actions.setLike(.like, videoID: "v") }
    #expect(spy.requests.isEmpty)
  }

  @Test func validationRequiresExplicitSignedInEvidence() async throws {
    for body in [#"{}"#, #"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":true}}}"#] {
      let actions = AccountActions(client: try makeClient(SpyTransport(body: Data(body.utf8)), session: testSession))
      await #expect(throws: MioTubeError.unauthorized) { try await actions.validateSession() }
    }
    let spy = SpyTransport(body: Self.ok)
    try await AccountActions(client: makeClient(spy, session: testSession)).validateSession()
    #expect(spy.requests.first?.retryable == true)
  }

  @Test func playlistMembershipUsesIssuedActionsIncludingItemSetIDs() async throws {
    let add: JSONValue = ["playlistId": "PL1", "params": "opaque%3D", "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": "video"]]]
    let remove: JSONValue = ["playlistId": "PL1", "params": "remove%3D", "actions": [["action": "ACTION_REMOVE_VIDEO", "setVideoId": "playlist-item-set-id"]]]
    let option = try #require(AccountActions.parsePlaylistOptions([
      "contents": [["playlistAddToOptionRenderer": [
        "playlistId": "PL1", "title": ["simpleText": "Mix"], "containsSelectedVideos": "ALL",
        "addToPlaylistServiceEndpoint": ["playlistEditEndpoint": add],
        "removeFromPlaylistServiceEndpoint": ["playlistEditEndpoint": remove],
      ]]],
    ]).first)
    let spy = SpyTransport(body: Data(#"{"status":"STATUS_SUCCEEDED"}"#.utf8))
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    try await actions.setPlaylistMembership(true, option: option)
    try await actions.setPlaylistMembership(false, option: option)
    #expect(spy.requests[0].jsonBody?["actions"] == add["actions"])
    #expect(spy.requests[1].jsonBody?["actions"] == remove["actions"])
    #expect(spy.requests[1].jsonBody?["params"] == "remove%3D")
    #expect(spy.requests.allSatisfy { !$0.retryable && $0.url.path == "/youtubei/v1/browse/edit_playlist" })
  }

  @Test func failedPlaylistMutationAndMissingCommandAreNotSuccess() async throws {
    let request: JSONValue = ["playlistId": "WL", "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": "video"]]]
    let option = PlaylistOption(playlistID: "WL", title: "Watch later", containsVideo: false, addRequest: request)
    for body in [#"{"status":"STATUS_FAILED"}"#, #"{}"#] {
      let actions = AccountActions(client: try makeClient(SpyTransport(body: Data(body.utf8)), session: testSession))
      await #expect(throws: MioTubeError.self) { try await actions.setPlaylistMembership(true, option: option) }
    }
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    await #expect(throws: MioTubeError.self) { try await actions.setPlaylistMembership(false, option: option) }
    #expect(spy.requests.isEmpty)
  }

  @Test func mutationPopupDoesNotCountAsSuccessfulWrite() async throws {
    let spy = SpyTransport(body: Data(#"{"actions":[{"openPopupAction":{"popup":{"modalWithTitleAndButtonRenderer":{"title":{"simpleText":"Sign in"}}}}}]}"#.utf8))
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    await #expect(throws: MioTubeError.self) { try await actions.setLike(.like, videoID: "v") }
  }

  @Test func accountMenuRequiresAccountHeader() async throws {
    let missing = AccountActions(client: try makeClient(SpyTransport(body: Self.ok), session: testSession))
    await #expect(throws: MioTubeError.self) { try await missing.accountInfo() }
    let body: JSONValue = [
      "responseContext": ["mainAppWebResponseContext": ["loggedOut": false]],
      "actions": [["openPopupAction": ["popup": ["multiPageMenuRenderer": ["header": ["activeAccountHeaderRenderer": [
        "accountName": ["simpleText": "Mio"], "accountPhoto": ["thumbnails": [["url": "https://yt3/p.jpg", "width": 88]]],
      ]]]]]]],
    ]
    let actions = AccountActions(client: try makeClient(SpyTransport(body: body.encoded()), session: testSession))
    #expect(try await actions.accountInfo() == AccountInfo(name: "Mio", avatarURL: URL(string: "https://yt3/p.jpg")))
  }
}

extension AccountActionsTests {
  @Test func watchCommandsKeepDifferentSubscribeAndUnsubscribeParams() throws {
    var info = WatchInfo(videoID: "video")
    WatchParser.parseSecondary(["subscribeButton": ["subscribeButtonRenderer": [
      "channelId": "UC1", "subscribed": true,
      "onSubscribeEndpoints": [["subscribeEndpoint": ["params": "SUB%3D"]]],
      "onUnsubscribeEndpoints": [["signalServiceEndpoint": ["actions": [["openPopupAction": ["popup": [
        "confirmDialogRenderer": ["confirmButton": ["buttonRenderer": ["serviceEndpoint": [
          "unsubscribeEndpoint": ["channelIds": ["UC1"], "params": "UNSUB%3D"],
        ]]]],
      ]]]]]]],
    ]]], into: &info)
    #expect(info.subscribe?.params == "SUB%3D")
    #expect(info.subscribe?.unsubscribeParams == "UNSUB%3D")
  }

  @Test func watchRatingCommandsPreserveAllFourOpaqueParams() {
    var info = WatchInfo(videoID: "video")
    WatchParser.parsePrimary(["videoActions": ["menuRenderer": ["topLevelButtons": [
      ["segmentedLikeDislikeButtonViewModel": [
        "likeButtonViewModel": ["likeButtonViewModel": ["commands": [
          ["likeEndpoint": ["status": "LIKE", "likeParams": "like%3D"]],
          ["likeEndpoint": ["status": "INDIFFERENT", "removeLikeParams": "remove-like%3D"]],
        ]]],
        "dislikeButtonViewModel": ["dislikeButtonViewModel": ["commands": [
          ["likeEndpoint": ["status": "DISLIKE", "dislikeParams": "dislike%3D"]],
          ["likeEndpoint": ["status": "INDIFFERENT", "removeLikeParams": "remove-dislike%3D"]],
        ]]],
      ]],
    ]]]], into: &info)
    #expect(info.likeParams == "like%3D" && info.dislikeParams == "dislike%3D")
    #expect(info.removeLikeParams == "remove-like%3D" && info.removeDislikeParams == "remove-dislike%3D")
  }

  @Test func anotherAccountCannotReuseIssuedPlaylistCommands() async throws {
    let json: JSONValue = ["contents": [["playlistAddToOptionRenderer": [
      "playlistId": "WL", "title": ["simpleText": "Watch later"], "containsSelectedVideos": "NONE",
      "addToPlaylistServiceEndpoint": ["playlistEditEndpoint": [
        "playlistId": "WL", "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": "video"]],
      ]],
    ]]]]
    let option = try #require(AccountActions.parsePlaylistOptions(json, expectedSession: testSession).first)
    var replacement = testSession
    replacement.accountIndex = 1
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy, session: replacement))
    await #expect(throws: CancellationError.self) { try await actions.setPlaylistMembership(true, option: option) }
    #expect(spy.requests.isEmpty)
  }
}
