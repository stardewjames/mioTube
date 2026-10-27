import Foundation
import Testing
@testable import MioTubeCore

@Suite struct AccountActionsTests {
  static let ok = Data(#"{"responseContext":{"mainAppWebResponseContext":{"loggedOut":false}}}"#.utf8)

  @Test func likeRoundTripBodies() async throws {
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    try await actions.setLike(.like, videoID: "v1")
    try await actions.setLike(.dislike, videoID: "v1")
    try await actions.setLike(.none, videoID: "v1")
    #expect(spy.requests.map(\.url.path) == ["/youtubei/v1/like/like", "/youtubei/v1/like/dislike", "/youtubei/v1/like/removelike"])
    #expect(spy.requests.allSatisfy { $0.jsonBody?["target", "videoId"] == "v1" && $0.headers["Authorization"] != nil })
  }

  @Test func subscribeSendsParamsOnlyWhenKnown() async throws {
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    try await actions.setSubscribed(true, channelID: "UC1", params: "P")
    try await actions.setSubscribed(false, channelID: "UC1", params: "P")
    #expect(spy.requests[0].url.path == "/youtubei/v1/subscription/subscribe")
    #expect(spy.requests[0].jsonBody?["params"] == "P")
    #expect(spy.requests[1].url.path == "/youtubei/v1/subscription/unsubscribe")
    #expect(spy.requests[1].jsonBody?["params"] == nil)
    #expect(spy.requests[1].jsonBody?["channelIds", "0"] == "UC1")
  }

  @Test func writesRequireSession() async throws {
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy))
    await #expect(throws: MioTubeError.notSignedIn) { try await actions.setLike(.like, videoID: "v") }
    #expect(spy.requests.isEmpty)
  }

  @Test func addToPlaylistBody() async throws {
    let spy = SpyTransport(body: Self.ok)
    let actions = AccountActions(client: try makeClient(spy, session: testSession))
    try await actions.addToPlaylist(videoID: "v", playlistID: "PL1")
    let body = try #require(spy.requests.first?.jsonBody)
    #expect(spy.requests.first?.url.path == "/youtubei/v1/browse/edit_playlist")
    #expect(body["actions", "0"] == ["action": "ACTION_ADD_VIDEO", "addedVideoId": "v"])
  }

  @Test func parsesPlaylistOptionsAndAccount() throws {
    let options = AccountActions.parsePlaylistOptions([
      "contents": [["addToPlaylistRenderer": ["playlists": [
        ["playlistAddToOptionRenderer": ["playlistId": "WL", "title": ["simpleText": "Watch later"], "containsSelectedVideos": "NONE"]],
        ["playlistAddToOptionRenderer": ["playlistId": "PL2", "title": ["simpleText": "Mix"], "containsSelectedVideos": "ALL"]],
      ]]]],
    ])
    #expect(options == [
      PlaylistOption(playlistID: "WL", title: "Watch later", containsVideo: false),
      PlaylistOption(playlistID: "PL2", title: "Mix", containsVideo: true),
    ])
    let account = AccountActions.parseAccountInfo([
      "actions": [["openPopupAction": ["popup": ["multiPageMenuRenderer": ["header": ["activeAccountHeaderRenderer": [
        "accountName": ["simpleText": "Mio"], "accountPhoto": ["thumbnails": [["url": "https://yt3/p.jpg", "width": 88]]],
      ]]]]]]],
    ])
    #expect(account == AccountInfo(name: "Mio", avatarURL: URL(string: "https://yt3/p.jpg")))
  }
}
