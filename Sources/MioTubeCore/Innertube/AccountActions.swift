import Foundation

public struct AccountInfo: Sendable, Equatable {
  public let name: String?
  public let avatarURL: URL?

  public init(name: String?, avatarURL: URL?) {
    self.name = name
    self.avatarURL = avatarURL
  }
}

public struct PlaylistOption: Sendable, Hashable, Identifiable {
  public let playlistID: String
  public let title: String
  public let containsVideo: Bool
  public var id: String { playlistID }

  public init(playlistID: String, title: String, containsVideo: Bool) {
    self.playlistID = playlistID
    self.title = title
    self.containsVideo = containsVideo
  }
}

/// Signed-in write actions, all through the metadata profile with cookies + SAPISIDHASH.
public struct AccountActions: Sendable {
  public let client: InnertubeClient

  public init(client: InnertubeClient) {
    self.client = client
  }

  private func requireSession() async throws {
    guard await client.hasSession() else { throw MioTubeError.notSignedIn }
  }

  public func setLike(_ status: LikeStatus, videoID: String) async throws {
    try await requireSession()
    let endpoint = switch status {
    case .like: "like/like"
    case .dislike: "like/dislike"
    case .none: "like/removelike"
    }
    _ = try await client.post(endpoint, ["target": ["videoId": .string(videoID)]])
  }

  /// `params` comes from the watch page's `subscribeButtonRenderer`; omitted when absent.
  public func setSubscribed(_ subscribed: Bool, channelID: String, params: String?) async throws {
    try await requireSession()
    var body: [String: JSONValue] = ["channelIds": [.string(channelID)]]
    if subscribed, let params { body["params"] = .string(params) }
    _ = try await client.post(subscribed ? "subscription/subscribe" : "subscription/unsubscribe", .object(body))
  }

  public func playlistOptions(videoID: String) async throws -> [PlaylistOption] {
    try await requireSession()
    let json = try await client.post("playlist/get_add_to_playlist", ["videoIds": [.string(videoID)]])
    return Self.parsePlaylistOptions(json)
  }

  public func addToPlaylist(videoID: String, playlistID: String) async throws {
    try await requireSession()
    _ = try await client.post("browse/edit_playlist", [
      "playlistId": .string(playlistID),
      "actions": [["action": "ACTION_ADD_VIDEO", "addedVideoId": .string(videoID)]],
    ])
  }

  public func removeFromPlaylist(videoID: String, playlistID: String) async throws {
    try await requireSession()
    _ = try await client.post("browse/edit_playlist", [
      "playlistId": .string(playlistID),
      "actions": [["action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID", "removedVideoId": .string(videoID)]],
    ])
  }

  /// Name + avatar of the signed-in account.
  public func accountInfo() async throws -> AccountInfo {
    try await requireSession()
    return Self.parseAccountInfo(try await client.post("account/account_menu", [:]))
  }

  /// Throws `.unauthorized` when the cookies no longer authenticate.
  public func validateSession() async throws {
    try await requireSession()
    _ = try await client.post("browse", ["browseId": "FEwhat_to_watch"])
  }

  static func parsePlaylistOptions(_ json: JSONValue) -> [PlaylistOption] {
    var options: [PlaylistOption] = []
    RendererTree.walk(json) { key, value in
      guard key == "playlistAddToOptionRenderer", let id = value["playlistId"]?.string else { return }
      options.append(PlaylistOption(
        playlistID: id,
        title: value["title"]?.text ?? id,
        containsVideo: value["containsSelectedVideos"]?.string == "ALL"
      ))
    }
    return options
  }

  static func parseAccountInfo(_ json: JSONValue) -> AccountInfo {
    guard let header = json.first(key: "activeAccountHeaderRenderer") else { return AccountInfo(name: nil, avatarURL: nil) }
    return AccountInfo(name: header["accountName"]?.text, avatarURL: header["accountPhoto"]?.firstThumbnailURL())
  }
}
