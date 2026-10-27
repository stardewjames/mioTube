import Foundation

public struct VideoSummary: Identifiable, Sendable, Hashable, Codable {
  public let videoID: String
  public let title: String
  public let channelID: String
  public let channelName: String
  public let thumbnailURL: URL?
  public let durationSeconds: Int?
  public let viewCountText: String?
  public let publishedText: String?
  public let isLive: Bool
  public let isUpcoming: Bool
  public var id: String { videoID }

  public init(
    videoID: String, title: String, channelID: String, channelName: String, thumbnailURL: URL?,
    durationSeconds: Int?, viewCountText: String?, publishedText: String?, isLive: Bool, isUpcoming: Bool
  ) {
    self.videoID = videoID
    self.title = title
    self.channelID = channelID
    self.channelName = channelName
    self.thumbnailURL = thumbnailURL
    self.durationSeconds = durationSeconds
    self.viewCountText = viewCountText
    self.publishedText = publishedText
    self.isLive = isLive
    self.isUpcoming = isUpcoming
  }

  /// Always-available thumbnail when the renderer omitted one.
  public var bestThumbnailURL: URL? {
    thumbnailURL ?? URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
  }
}

public struct PlaylistSummary: Identifiable, Sendable, Hashable, Codable {
  public let playlistID: String
  public let title: String
  public let thumbnailURL: URL?
  public let videoCountText: String?
  public let author: String
  public var id: String { playlistID }

  public init(playlistID: String, title: String, thumbnailURL: URL?, videoCountText: String?, author: String) {
    self.playlistID = playlistID
    self.title = title
    self.thumbnailURL = thumbnailURL
    self.videoCountText = videoCountText
    self.author = author
  }
}

public struct ChannelSummary: Identifiable, Sendable, Hashable, Codable {
  public let channelID: String
  public let title: String
  public let thumbnailURL: URL?
  public let subscriberText: String?
  public let handle: String
  public var id: String { channelID }

  public init(channelID: String, title: String, thumbnailURL: URL?, subscriberText: String?, handle: String) {
    self.channelID = channelID
    self.title = title
    self.thumbnailURL = thumbnailURL
    self.subscriberText = subscriberText
    self.handle = handle
  }
}

public enum FeedItem: Identifiable, Sendable, Hashable, Codable {
  case video(VideoSummary)
  case playlist(PlaylistSummary)
  case channel(ChannelSummary)

  public var id: String {
    switch self {
    case .video(let v): "v:" + v.videoID
    case .playlist(let p): "p:" + p.playlistID
    case .channel(let c): "c:" + c.channelID
    }
  }

  public var title: String {
    switch self {
    case .video(let v): v.title
    case .playlist(let p): p.title
    case .channel(let c): c.title
    }
  }

  public var video: VideoSummary? {
    if case .video(let v) = self { return v }
    return nil
  }
}

public struct FeedSection: Identifiable, Sendable, Hashable, Codable {
  public let id: String
  public let title: String?
  public let items: [FeedItem]
  public let continuation: String?

  public init(id: String, title: String?, items: [FeedItem], continuation: String?) {
    self.id = id
    self.title = title
    self.items = items
    self.continuation = continuation
  }
}

/// Search filter chip. Selecting it re-requests `search` with `params`, or with
/// `{continuation: token}` for 2026-style chips that carry a continuation command.
public struct SearchChip: Identifiable, Sendable, Hashable, Codable {
  public let title: String
  public let params: String?
  public let token: String?
  public let isSelected: Bool
  public var id: String { title }

  public init(title: String, params: String?, token: String?, isSelected: Bool) {
    self.title = title
    self.params = params
    self.token = token
    self.isSelected = isSelected
  }
}

/// Channel / playlist page header.
public struct FeedHeader: Sendable, Hashable, Codable {
  public let title: String
  public let subtitle: String?
  public let avatarURL: URL?
  public let bannerURL: URL?

  public init(title: String, subtitle: String?, avatarURL: URL?, bannerURL: URL?) {
    self.title = title
    self.subtitle = subtitle
    self.avatarURL = avatarURL
    self.bannerURL = bannerURL
  }
}

public struct ChannelTab: Sendable, Hashable, Codable {
  public let title: String
  public let params: String?
  public let isSelected: Bool

  public init(title: String, params: String?, isSelected: Bool) {
    self.title = title
    self.params = params
    self.isSelected = isSelected
  }
}

public struct FeedPage: Sendable, Hashable, Codable {
  public let sections: [FeedSection]
  public let continuation: String?
  public let droppedAds: Int
  public var chips: [SearchChip]
  public var header: FeedHeader?
  public var tabs: [ChannelTab]
  /// Text YouTube shows instead of a feed (e.g. signed-out "Try searching to get started").
  public var notice: String?

  public init(
    sections: [FeedSection], continuation: String?, droppedAds: Int, chips: [SearchChip] = [],
    header: FeedHeader? = nil, tabs: [ChannelTab] = [], notice: String? = nil
  ) {
    self.sections = sections
    self.continuation = continuation
    self.droppedAds = droppedAds
    self.chips = chips
    self.header = header
    self.tabs = tabs
    self.notice = notice
  }

  public var items: [FeedItem] { sections.flatMap(\.items) }
  public var videos: [VideoSummary] { items.compactMap(\.video) }
}

public struct Comment: Identifiable, Sendable, Hashable, Codable {
  public let id: String
  public let author: String
  public let authorAvatarURL: URL?
  public let text: String
  public let publishedText: String?
  public let likeCountText: String?
  public let replyCount: Int
  public let isPinned: Bool
  public let isCreator: Bool
  public let repliesContinuation: String?

  public init(
    id: String, author: String, authorAvatarURL: URL?, text: String, publishedText: String?,
    likeCountText: String?, replyCount: Int, isPinned: Bool, isCreator: Bool, repliesContinuation: String?
  ) {
    self.id = id
    self.author = author
    self.authorAvatarURL = authorAvatarURL
    self.text = text
    self.publishedText = publishedText
    self.likeCountText = likeCountText
    self.replyCount = replyCount
    self.isPinned = isPinned
    self.isCreator = isCreator
    self.repliesContinuation = repliesContinuation
  }
}

public struct CommentSortOption: Identifiable, Sendable, Hashable, Codable {
  public let title: String
  public let token: String
  public let isSelected: Bool
  public var id: String { title }

  public init(title: String, token: String, isSelected: Bool) {
    self.title = title
    self.token = token
    self.isSelected = isSelected
  }
}

public struct CommentsPage: Sendable, Hashable {
  public let comments: [Comment]
  public let continuation: String?
  public let sortOptions: [CommentSortOption]
  public let countText: String?

  public init(comments: [Comment], continuation: String?, sortOptions: [CommentSortOption], countText: String?) {
    self.comments = comments
    self.continuation = continuation
    self.sortOptions = sortOptions
    self.countText = countText
  }
}

/// "12:34" / "1:02:03" → seconds.
public func parseDurationText(_ text: String) -> Int? {
  let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":")
  guard (2...3).contains(parts.count) else { return nil }
  var total = 0
  for part in parts {
    guard let value = Int(part) else { return nil }
    total = total * 60 + value
  }
  return total
}
