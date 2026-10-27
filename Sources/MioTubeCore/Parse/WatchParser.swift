import Foundation

public struct Chapter: Sendable, Hashable, Codable {
  public let title: String
  public let startSeconds: Double

  public init(title: String, startSeconds: Double) {
    self.title = title
    self.startSeconds = startSeconds
  }
}

public struct CaptionTrack: Sendable, Hashable, Codable, Identifiable {
  public let baseURL: URL
  public let languageCode: String
  public let name: String
  public let isAutomatic: Bool
  public var id: String { "\(languageCode)|\(isAutomatic)|\(name)" }

  public init(baseURL: URL, languageCode: String, name: String, isAutomatic: Bool) {
    self.baseURL = baseURL
    self.languageCode = languageCode
    self.name = name
    self.isAutomatic = isAutomatic
  }
}

public struct SubscribeState: Sendable, Hashable {
  public let channelID: String
  /// `subscribeEndpoint.params` when YouTube supplied one (signed-in responses); sent verbatim.
  public let params: String?
  public let isSubscribed: Bool

  public init(channelID: String, params: String?, isSubscribed: Bool) {
    self.channelID = channelID
    self.params = params
    self.isSubscribed = isSubscribed
  }
}

public enum LikeStatus: String, Sendable, Hashable {
  case none, like, dislike
}

public struct WatchInfo: Sendable, Hashable {
  public var videoID: String
  public var title: String
  public var description: String
  public var viewCountText: String?
  public var likeCountText: String?
  public var publishedText: String?
  public var channel: ChannelSummary?
  public var chapters: [Chapter]
  public var related: [VideoSummary]
  public var relatedContinuation: String?
  public var commentsContinuation: String?
  public var commentsCountText: String?
  public var captionTracks: [CaptionTrack]
  public var isLive: Bool
  public var likeStatus: LikeStatus
  public var subscribe: SubscribeState?
  public var durationSeconds: Double?
  /// Ad renderers removed from the `next` response (Diagnostics).
  public var droppedAds: Int

  public init(videoID: String) {
    self.videoID = videoID
    title = ""
    description = ""
    chapters = []
    related = []
    captionTracks = []
    isLive = false
    likeStatus = .none
    droppedAds = 0
  }

  /// Minimal info for queue items played before `next` arrives.
  public init(summary: VideoSummary) {
    self.init(videoID: summary.videoID)
    title = summary.title
    viewCountText = summary.viewCountText
    publishedText = summary.publishedText
    isLive = summary.isLive
    durationSeconds = summary.durationSeconds.map(Double.init)
    channel = ChannelSummary(
      channelID: summary.channelID, title: summary.channelName, thumbnailURL: nil, subscriberText: nil, handle: ""
    )
  }
}

public enum WatchParser {
  public static func parse(next: JSONValue, player: JSONValue, adFilter: AdFilter) -> WatchInfo {
    var next = next
    let dropped = adFilter.filter(&next)
    let videoID = player["videoDetails", "videoId"]?.string
      ?? next["currentVideoEndpoint", "watchEndpoint", "videoId"]?.string ?? ""
    var info = WatchInfo(videoID: videoID)
    info.droppedAds = dropped

    let results = next["contents", "twoColumnWatchNextResults", "results", "results", "contents"]?.array ?? []
    for entry in results {
      if let primary = entry["videoPrimaryInfoRenderer"] { parsePrimary(primary, into: &info) }
      if let secondary = entry["videoSecondaryInfoRenderer"] { parseSecondary(secondary, into: &info) }
      if let section = entry["itemSectionRenderer"], section["sectionIdentifier"]?.string == "comment-item-section" {
        info.commentsContinuation = info.commentsContinuation
          ?? section["contents"]?.array?.lazy.compactMap { $0["continuationItemRenderer"].flatMap(RendererTree.continuationToken) }.first
      }
    }
    if info.commentsContinuation == nil { info.commentsContinuation = commentsTokenFromPanels(next) }
    info.commentsCountText = commentsCount(next)

    // Player response fills gaps and is authoritative for duration, live state, captions.
    let details = player["videoDetails"]
    if info.title.isEmpty { info.title = details?["title"]?.string ?? "" }
    if info.description.isEmpty { info.description = details?["shortDescription"]?.string ?? "" }
    if info.channel == nil, let channelID = details?["channelId"]?.string {
      info.channel = ChannelSummary(
        channelID: channelID, title: details?["author"]?.string ?? "", thumbnailURL: nil, subscriberText: nil, handle: ""
      )
    }
    info.durationSeconds = details?["lengthSeconds"]?.double.flatMap { $0 > 0 ? $0 : nil }
    info.isLive = details?["isLive"]?.bool ?? details?["isLiveContent"]?.bool.flatMap { $0 && info.durationSeconds == nil ? true : nil } ?? false
    info.captionTracks = captionTracks(player)
    info.chapters = chapters(next, videoID: videoID)
    (info.related, info.relatedContinuation) = related(next, excluding: videoID)
    return info
  }

  static func parsePrimary(_ v: JSONValue, into info: inout WatchInfo) {
    info.title = v["title"]?.text ?? info.title
    info.viewCountText = v["viewCount", "videoViewCountRenderer", "viewCount"]?.text
    info.publishedText = v["dateText"]?.text ?? v["relativeDateText"]?.text
    if v["viewCount", "videoViewCountRenderer", "isLive"]?.bool == true { info.isLive = true }
    guard let buttons = v["videoActions", "menuRenderer", "topLevelButtons"]?.array else { return }
    for button in buttons {
      guard let segmented = button["segmentedLikeDislikeButtonViewModel"] else { continue }
      let like = segmented["likeButtonViewModel", "likeButtonViewModel"]
      info.likeCountText = like?["toggleButtonViewModel", "toggleButtonViewModel", "defaultButtonViewModel", "buttonViewModel", "title"]?.string
      switch like?["likeStatusEntity", "likeStatus"]?.string {
      case "LIKE": info.likeStatus = .like
      case "DISLIKE": info.likeStatus = .dislike
      default:
        let toggled = like?["toggleButtonViewModel", "toggleButtonViewModel", "isToggled"]?.bool == true
        let disliked = segmented["dislikeButtonViewModel", "dislikeButtonViewModel", "toggleButtonViewModel", "toggleButtonViewModel", "isToggled"]?.bool == true
        info.likeStatus = toggled ? .like : (disliked ? .dislike : .none)
      }
    }
  }

  static func parseSecondary(_ v: JSONValue, into info: inout WatchInfo) {
    info.description = v["attributedDescription", "content"]?.string ?? v["description"]?.text ?? info.description
    if let owner = v["owner", "videoOwnerRenderer"], let channelID = owner["navigationEndpoint", "browseEndpoint", "browseId"]?.string {
      info.channel = ChannelSummary(
        channelID: channelID,
        title: owner["title"]?.text ?? "",
        thumbnailURL: owner["thumbnail"]?.firstThumbnailURL(),
        subscriberText: owner["subscriberCountText"]?.text,
        handle: owner["navigationEndpoint", "browseEndpoint", "canonicalBaseUrl"]?.string.map { $0.hasPrefix("/@") ? String($0.dropFirst()) : "" } ?? ""
      )
    }
    let button = v["subscribeButton", "subscribeButtonRenderer"] ?? v["owner", "videoOwnerRenderer", "subscribeButton", "subscribeButtonRenderer"]
    if let button, let channelID = button["channelId"]?.string ?? info.channel?.channelID {
      info.subscribe = SubscribeState(
        channelID: channelID,
        params: button["onSubscribeEndpoints", "0", "subscribeEndpoint", "params"]?.string,
        isSubscribed: button["subscribed"]?.bool ?? false
      )
    }
  }

  static func commentsTokenFromPanels(_ next: JSONValue) -> String? {
    for panel in next["engagementPanels"]?.array ?? [] {
      guard let renderer = panel["engagementPanelSectionListRenderer"] else { continue }
      let id = renderer["panelIdentifier"]?.string ?? renderer["targetId"]?.string ?? ""
      guard id.contains("comment") else { continue }
      if let header = renderer["content"]?.first(key: "commentsEntryPointHeaderRenderer"),
         let token = header.first(key: "continuationCommand")?["token"]?.string {
        return token
      }
      if let item = renderer["content"]?.first(key: "continuationItemRenderer"), let token = RendererTree.continuationToken(item) {
        return token
      }
    }
    return nil
  }

  static func commentsCount(_ next: JSONValue) -> String? {
    for panel in next["engagementPanels"]?.array ?? [] {
      guard let renderer = panel["engagementPanelSectionListRenderer"],
            renderer["panelIdentifier"]?.string == "engagement-panel-comments-section" else { continue }
      return renderer["header", "engagementPanelTitleHeaderRenderer", "contextualInfo"]?.text
    }
    return nil
  }

  static func captionTracks(_ player: JSONValue) -> [CaptionTrack] {
    (player["captions", "playerCaptionsTracklistRenderer", "captionTracks"]?.array ?? []).compactMap { track in
      guard let raw = track["baseUrl"]?.string, let url = JSONValue.normalizedURL(raw.hasPrefix("/") && !raw.hasPrefix("//") ? "https://www.youtube.com" + raw : raw),
            let code = track["languageCode"]?.string else { return nil }
      return CaptionTrack(
        baseURL: url, languageCode: code, name: track["name"]?.text ?? code, isAutomatic: track["kind"]?.string == "asr"
      )
    }
  }

  /// Player-bar chapters (authoritative), falling back to description timestamps that point
  /// at this same video.
  static func chapters(_ next: JSONValue, videoID: String) -> [Chapter] {
    var result: [Chapter] = []
    let markers = next["playerOverlays", "playerOverlayRenderer", "decoratedPlayerBarRenderer", "decoratedPlayerBarRenderer",
                       "playerBar", "multiMarkersPlayerBarRenderer", "markersMap"]?.array ?? []
    if let map = markers.first(where: { $0["key"]?.string == "DESCRIPTION_CHAPTERS" }) ?? markers.first(where: { $0["value", "chapters"] != nil }) {
      for chapter in map["value", "chapters"]?.array ?? [] {
        guard let renderer = chapter["chapterRenderer"], let title = renderer["title"]?.text,
              let millis = renderer["timeRangeStartMillis"]?.double else { continue }
        result.append(Chapter(title: title, startSeconds: millis / 1000))
      }
    }
    if result.isEmpty, let description = next.first(key: "attributedDescription") {
      let content = description["content"]?.string ?? ""
      let utf16 = Array(content.utf16)
      for run in description["commandRuns"]?.array ?? [] {
        guard let endpoint = run["onTap", "innertubeCommand", "watchEndpoint"],
              endpoint["videoId"]?.string == videoID,
              let start = endpoint["startTimeSeconds"]?.double,
              let from = run["startIndex"]?.int, let length = run["length"]?.int,
              from >= 0, from + length <= utf16.count else { continue }
        // The chapter title is the rest of the line after the timestamp link.
        var end = from + length
        while end < utf16.count, utf16[end] != 0x0A { end += 1 }
        let line = String(decoding: utf16[(from + length)..<end], as: UTF16.self)
          .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "-–—:|")))
        result.append(Chapter(title: line.isEmpty ? String(decoding: utf16[from..<(from + length)], as: UTF16.self) : line, startSeconds: start))
      }
    }
    var seen = Set<Double>()
    return result.sorted { $0.startSeconds < $1.startSeconds }.filter { seen.insert($0.startSeconds).inserted }
  }

  static func related(_ next: JSONValue, excluding videoID: String) -> ([VideoSummary], String?) {
    let results = next["contents", "twoColumnWatchNextResults", "secondaryResults", "secondaryResults", "results"]?.array ?? []
    var videos: [VideoSummary] = []
    var seen: Set<String> = [videoID]
    var continuation: String?
    func visit(_ v: JSONValue) {
      guard let object = v.object else {
        v.array?.forEach(visit)
        return
      }
      for (key, value) in object {
        if let item = ItemParser.parse(key, value) {
          if case .video(let video) = item, seen.insert(video.videoID).inserted { videos.append(video) }
        } else if key == "continuationItemRenderer" {
          continuation = RendererTree.continuationToken(value)
        } else if key != "menu" && key != "header" {
          visit(value)
        }
      }
    }
    results.forEach(visit)
    return (videos, continuation)
  }
}

public enum CommentsParser {
  public static func parse(_ json: JSONValue) -> CommentsPage {
    var entities: [String: JSONValue] = [:]
    for mutation in json["frameworkUpdates", "entityBatchUpdate", "mutations"]?.array ?? [] {
      if let key = mutation["entityKey"]?.string, let payload = mutation["payload", "commentEntityPayload"] {
        entities[key] = payload
      }
    }
    var comments: [Comment] = []
    var continuation: String?
    var sortOptions: [CommentSortOption] = []
    var countText: String?

    var items: [JSONValue] = []
    for key in ["onResponseReceivedEndpoints", "onResponseReceivedActions"] {
      for action in json[key]?.array ?? [] {
        items += action["reloadContinuationItemsCommand", "continuationItems"]?.array ?? []
        items += action["appendContinuationItemsAction", "continuationItems"]?.array ?? []
      }
    }
    for item in items {
      if let thread = item["commentThreadRenderer"] {
        if let comment = threadComment(thread, entities: entities) { comments.append(comment) }
      } else if let reply = item["commentViewModel"] {
        if let comment = viewModelComment(reply, entities: entities, repliesContinuation: nil) { comments.append(comment) }
      } else if let renderer = item["commentRenderer"] {
        if let comment = legacyComment(renderer, repliesContinuation: nil) { comments.append(comment) }
      } else if let more = item["continuationItemRenderer"] {
        continuation = RendererTree.continuationToken(more)
      } else if let header = item["commentsHeaderRenderer"] {
        countText = header["countText"]?.text ?? header["commentsCount"]?.text
        for option in header.first(key: "subMenuItems")?.array ?? [] {
          guard let title = option["title"]?.string,
                let token = option["serviceEndpoint", "continuationCommand", "token"]?.string else { continue }
          sortOptions.append(CommentSortOption(title: title, token: token, isSelected: option["selected"]?.bool ?? false))
        }
      }
    }
    return CommentsPage(comments: comments, continuation: continuation, sortOptions: sortOptions, countText: countText)
  }

  static func threadComment(_ thread: JSONValue, entities: [String: JSONValue]) -> Comment? {
    let repliesToken = thread["replies", "commentRepliesRenderer", "contents"]?.array?.lazy
      .compactMap { $0["continuationItemRenderer"].flatMap(RendererTree.continuationToken) }.first
    if let model = thread["commentViewModel", "commentViewModel"] {
      return viewModelComment(model, entities: entities, repliesContinuation: repliesToken)
    }
    if let renderer = thread["comment", "commentRenderer"] {
      return legacyComment(renderer, repliesContinuation: repliesToken)
    }
    return nil
  }

  static func viewModelComment(_ model: JSONValue, entities: [String: JSONValue], repliesContinuation: String?) -> Comment? {
    guard let key = model["commentKey"]?.string, let entity = entities[key],
          let id = entity["properties", "commentId"]?.string else { return nil }
    let toolbar = entity["toolbar"]
    return Comment(
      id: id,
      author: entity["author", "displayName"]?.string ?? "",
      authorAvatarURL: entity["author", "avatarThumbnailUrl"]?.string.flatMap(JSONValue.normalizedURL),
      text: entity["properties", "content", "content"]?.string ?? "",
      publishedText: entity["properties", "publishedTime"]?.string,
      likeCountText: toolbar?["likeCountNotliked"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 },
      replyCount: toolbar?["replyCount"]?.int ?? 0,
      isPinned: model["pinnedText"] != nil,
      isCreator: entity["author", "isCreator"]?.bool ?? false,
      repliesContinuation: repliesContinuation
    )
  }

  static func legacyComment(_ renderer: JSONValue, repliesContinuation: String?) -> Comment? {
    guard let id = renderer["commentId"]?.string else { return nil }
    return Comment(
      id: id,
      author: renderer["authorText"]?.text ?? "",
      authorAvatarURL: renderer["authorThumbnail"]?.firstThumbnailURL(),
      text: renderer["contentText"]?.text ?? "",
      publishedText: renderer["publishedTimeText"]?.text,
      likeCountText: renderer["voteCount"]?.text,
      replyCount: renderer["replyCount"]?.int ?? 0,
      isPinned: renderer["pinnedCommentBadge"] != nil,
      isCreator: renderer["authorIsChannelOwner"]?.bool ?? false,
      repliesContinuation: repliesContinuation
    )
  }
}
