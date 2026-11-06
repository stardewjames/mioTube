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
  /// Server-issued edit bodies retain opaque params and playlist item set IDs.
  public let addRequest: JSONValue?
  public let removeRequest: JSONValue?
  fileprivate var expectedSession: GoogleSession?
  public var id: String { playlistID }

  public init(
    playlistID: String, title: String, containsVideo: Bool,
    addRequest: JSONValue? = nil, removeRequest: JSONValue? = nil
  ) {
    self.playlistID = playlistID
    self.title = title
    self.containsVideo = containsVideo
    self.addRequest = addRequest
    self.removeRequest = removeRequest
  }
}

/// Signed-in write actions, all through the metadata profile with cookies + SAPISIDHASH.
public struct AccountActions: Sendable {
  public let client: InnertubeClient

  public init(client: InnertubeClient) {
    self.client = client
  }

  private func requireSession() async throws -> GoogleSession {
    guard let session = await client.session.current(), session.hasAuthCookie else {
      throw MioTubeError.notSignedIn
    }
    guard session.expiresAt > Date() else { throw MioTubeError.unauthorized }
    return session
  }

  public func setLike(_ status: LikeStatus, videoID: String, params: String? = nil) async throws {
    let session = try await requireSession()
    let endpoint = switch status {
    case .like: "like/like"
    case .dislike: "like/dislike"
    case .none: "like/removelike"
    }
    var body: [String: JSONValue] = ["target": ["videoId": .string(videoID)]]
    if let params { body["params"] = .string(params) }
    let json = try await client.post(endpoint, .object(body), retryable: false, expectedSession: session)
    try Self.checkMutation(json)
  }

  /// Pass the matching subscribe or unsubscribe endpoint's params verbatim.
  public func setSubscribed(_ subscribed: Bool, channelID: String, params: String?) async throws {
    let session = try await requireSession()
    var body: [String: JSONValue] = ["channelIds": [.string(channelID)]]
    if let params { body["params"] = .string(params) }
    let json = try await client.post(
      subscribed ? "subscription/subscribe" : "subscription/unsubscribe", .object(body),
      retryable: false, expectedSession: session
    )
    try Self.checkMutation(json)
    if let update = json.first(key: "updateSubscribeButtonAction"),
       update["channelId"]?.string == channelID,
       let actual = update["subscribed"]?.bool, actual != subscribed {
      throw MioTubeError.invalidResponse("YouTube did not change the subscription.")
    }
  }

  public func playlistOptions(videoID: String) async throws -> [PlaylistOption] {
    let session = try await requireSession()
    let json = try await client.post(
      "playlist/get_add_to_playlist", ["videoIds": [.string(videoID)]], expectedSession: session
    )
    return Self.parsePlaylistOptions(json, expectedSession: session)
  }

  /// Uses the selected option's actual service endpoint, not an inferred video-ID removal.
  public func setPlaylistMembership(_ containsVideo: Bool, option: PlaylistOption) async throws {
    let session = try await requireSession()
    if let expected = option.expectedSession, !session.hasSameIdentity(as: expected) {
      throw CancellationError()
    }
    guard let body = containsVideo ? option.addRequest : option.removeRequest,
          body["playlistId"]?.string == option.playlistID,
          body["actions"]?.array?.isEmpty == false else {
      throw MioTubeError.invalidResponse("YouTube did not provide an editable playlist option.")
    }
    let json = try await client.post("browse/edit_playlist", body, retryable: false, expectedSession: session)
    try Self.checkMutation(json)
    guard json["status"]?.string == "STATUS_SUCCEEDED" else {
      throw MioTubeError.invalidResponse("YouTube did not confirm the playlist update.")
    }
  }

  /// Name + avatar of the signed-in account.
  public func accountInfo() async throws -> AccountInfo {
    let session = try await requireSession()
    let json = try await client.post("account/account_menu", [:], expectedSession: session)
    try Self.requireSignedInResponse(json)
    guard json.first(key: "activeAccountHeaderRenderer") != nil else {
      throw MioTubeError.invalidResponse("YouTube did not return the active account.")
    }
    return Self.parseAccountInfo(json)
  }

  /// Throws `.unauthorized` when the cookies no longer authenticate.
  public func validateSession() async throws {
    let session = try await requireSession()
    try Self.requireSignedInResponse(
      try await client.post("browse", ["browseId": "FEwhat_to_watch"], expectedSession: session)
    )
  }

  private static func requireSignedInResponse(_ json: JSONValue) throws {
    guard json["responseContext", "mainAppWebResponseContext", "loggedOut"]?.bool == false else {
      throw MioTubeError.unauthorized
    }
  }

  private static func checkMutation(_ json: JSONValue) throws {
    if json["responseContext", "mainAppWebResponseContext", "loggedOut"]?.bool == true {
      throw MioTubeError.unauthorized
    }
    if let status = json["status"]?.string, status != "STATUS_SUCCEEDED" {
      throw MioTubeError.invalidResponse("YouTube rejected the update (\(status)).")
    }
    var failure: String?
    RendererTree.walk(json) { key, value in
      if key == "alertRenderer", value["type"]?.string == "ERROR" {
        failure = value["text"]?.text ?? "YouTube rejected the update."
      }
      if key == "modalWithTitleAndButtonRenderer" {
        failure = value["content"]?.text ?? value["title"]?.text ?? "YouTube requires another action."
      }
    }
    if let failure { throw MioTubeError.invalidResponse(failure) }
  }

  static func parsePlaylistOptions(_ json: JSONValue, expectedSession: GoogleSession? = nil) -> [PlaylistOption] {
    var options: [PlaylistOption] = []
    RendererTree.walk(json) { key, value in
      guard key == "playlistAddToOptionRenderer", let id = value["playlistId"]?.string else { return }
      var option = PlaylistOption(
        playlistID: id,
        title: value["title"]?.text ?? id,
        containsVideo: value["containsSelectedVideos"]?.string == "ALL",
        addRequest: value["addToPlaylistServiceEndpoint", "playlistEditEndpoint"],
        removeRequest: value["removeFromPlaylistServiceEndpoint", "playlistEditEndpoint"]
      )
      option.expectedSession = expectedSession
      options.append(option)
    }
    return options
  }

  static func parseAccountInfo(_ json: JSONValue) -> AccountInfo {
    guard let header = json.first(key: "activeAccountHeaderRenderer") else { return AccountInfo(name: nil, avatarURL: nil) }
    return AccountInfo(name: header["accountName"]?.text, avatarURL: header["accountPhoto"]?.firstThumbnailURL())
  }
}
