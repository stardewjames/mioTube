import Foundation

/// Maps one item renderer (legacy or `lockupViewModel`) to a `FeedItem`.
enum ItemParser {
  /// Renderer keys that are items, in the precedence the plan defines. Anything else is a
  /// container (or noise) and is descended into by the caller.
  static let itemKeys: Set<String> = [
    "lockupViewModel", "videoRenderer", "gridVideoRenderer", "compactVideoRenderer",
    "playlistVideoRenderer", "videoWithContextRenderer", "playlistRenderer", "gridPlaylistRenderer",
    "compactPlaylistRenderer", "channelRenderer", "gridChannelRenderer",
  ]

  enum Outcome {
    case item(FeedItem)
    /// An item (or storefront renderer) that is streaming-service content; not shown, counted.
    case excluded
    case notItem
  }

  /// `parse` plus the streaming-service filter.
  static func parseFiltered(_ key: String, _ value: JSONValue) -> Outcome {
    if StreamingContentFilter.renderers.contains(key) { return .excluded }
    guard itemKeys.contains(key) else { return .notItem }
    if StreamingContentFilter.isServiceContent(value) { return .excluded }
    guard let item = parse(key, value) else {
      // Lockups of storefront types (movies, shows) parse to nil on purpose.
      return key == "lockupViewModel" && value["contentId"] != nil ? .excluded : .notItem
    }
    let owner = switch item {
    case .video(let video): video.channelName
    case .playlist(let playlist): playlist.author
    case .channel(let channel): channel.title
    }
    return StreamingContentFilter.isServiceOwner(owner) ? .excluded : .item(item)
  }

  static func parse(_ key: String, _ value: JSONValue) -> FeedItem? {
    guard itemKeys.contains(key) else { return nil }
    switch key {
    case "lockupViewModel": return lockup(value)
    case "videoRenderer", "gridVideoRenderer", "compactVideoRenderer", "playlistVideoRenderer", "videoWithContextRenderer":
      return legacyVideo(value).map(FeedItem.video)
    case "playlistRenderer", "gridPlaylistRenderer", "compactPlaylistRenderer":
      return legacyPlaylist(value).map(FeedItem.playlist)
    case "channelRenderer", "gridChannelRenderer":
      return legacyChannel(value).map(FeedItem.channel)
    default: return nil
    }
  }

  // MARK: Text classification (never trust row/part order)

  enum PartKind { case views, published, subscribers, count, other }

  static func classify(_ text: String) -> PartKind {
    let lower = text.lowercased().trimmingCharacters(in: .whitespaces)
    let startsWithDigit = lower.first?.isNumber == true
    if lower == "no views" || (startsWithDigit && (lower.hasSuffix(" views") || lower.hasSuffix(" view") || lower.hasSuffix(" watching"))) {
      return .views
    }
    if startsWithDigit && (lower.hasSuffix(" subscribers") || lower.hasSuffix(" subscriber")) { return .subscribers }
    if startsWithDigit && (lower.hasSuffix(" videos") || lower.hasSuffix(" video") || lower.hasSuffix(" episodes") || lower.hasSuffix(" lessons")) {
      return .count
    }
    if lower.hasSuffix(" ago") || lower.hasPrefix("premier") || lower.hasPrefix("streamed") || lower.hasPrefix("scheduled") {
      return .published
    }
    return .other
  }

  // MARK: lockupViewModel (2026)

  struct LockupMetadata {
    var views: String?
    var published: String?
    var subscribers: String?
    var count: String?
    var channelName: String?
    var channelID: String?
    var handle: String?
  }

  static func lockupMetadata(_ lockup: JSONValue) -> LockupMetadata {
    var meta = LockupMetadata()
    let rows = lockup["metadata", "lockupMetadataViewModel", "metadata", "contentMetadataViewModel", "metadataRows"]?.array ?? []
    for row in rows {
      for part in row["metadataParts"]?.array ?? [] {
        guard let content = part["text", "content"]?.string, !content.isEmpty else { continue }
        let label = part["accessibilityLabel"]?.string ?? content
        switch classify(label) == .other ? classify(content) : classify(label) {
        case .views:
          meta.views = meta.views ?? (content.lowercased().contains("view") || content.lowercased().contains("watching") ? content : (label.lowercased().contains("watching") ? label : "\(content) views"))
        case .published:
          meta.published = meta.published ?? content
        case .subscribers:
          meta.subscribers = meta.subscribers ?? content
        case .count:
          meta.count = meta.count ?? content
        case .other:
          if let browse = part["text", "commandRuns", "0", "onTap", "innertubeCommand", "browseEndpoint"],
             let id = browse["browseId"]?.string, id.hasPrefix("UC") {
            if meta.channelID == nil { meta.channelID = id; meta.channelName = content }
          } else if content.hasPrefix("@") {
            meta.handle = meta.handle ?? content
          } else if meta.channelName == nil {
            meta.channelName = content
          }
        }
      }
    }
    if meta.channelID == nil {
      meta.channelID = lockup["metadata", "lockupMetadataViewModel", "image", "decoratedAvatarViewModel", "rendererContext",
                              "commandContext", "onTap", "innertubeCommand", "browseEndpoint", "browseId"]?.string
    }
    return meta
  }

  static func lockup(_ v: JSONValue) -> FeedItem? {
    guard let id = v["contentId"]?.string, !id.isEmpty else { return nil }
    let title = v["metadata", "lockupMetadataViewModel", "title", "content"]?.string ?? ""
    guard !title.isEmpty else { return nil }
    let image = v["contentImage"]
    let thumbnail = image?["thumbnailViewModel", "image"]?.firstThumbnailURL()
      ?? image?["collectionThumbnailViewModel", "primaryThumbnail", "thumbnailViewModel", "image"]?.firstThumbnailURL()
    let meta = lockupMetadata(v)

    switch v["contentType"]?.string {
    case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_PODCAST":
      var countText = meta.count
      if countText == nil, let image {
        RendererTree.walk(image) { key, badge in
          if key == "thumbnailBadgeViewModel", countText == nil, let text = badge["text"]?.string { countText = text }
        }
      }
      return .playlist(PlaylistSummary(
        playlistID: id, title: title, thumbnailURL: thumbnail, videoCountText: countText,
        author: meta.channelName ?? ""
      ))
    case "LOCKUP_CONTENT_TYPE_CHANNEL":
      return .channel(ChannelSummary(
        channelID: id, title: title, thumbnailURL: thumbnail, subscriberText: meta.subscribers,
        handle: meta.handle ?? ""
      ))
    case "LOCKUP_CONTENT_TYPE_VIDEO", nil:
      var duration: Int?
      var live = false
      var upcoming = false
      if let image {
        RendererTree.walk(image) { key, badge in
          guard key == "thumbnailBadgeViewModel" else { return }
          let text = badge["text"]?.string ?? ""
          let style = badge["badgeStyle"]?.string ?? badge["style"]?.string ?? ""
          if style.hasSuffix("_LIVE") || text == "LIVE" { live = true }
          if text.uppercased() == "UPCOMING" { upcoming = true }
          if duration == nil, let seconds = parseDurationText(text) { duration = seconds }
        }
      }
      if meta.published?.lowercased().hasPrefix("scheduled") == true || meta.published?.lowercased().hasPrefix("premieres") == true {
        upcoming = true
      }
      return .video(VideoSummary(
        videoID: id, title: title, channelID: meta.channelID ?? "", channelName: meta.channelName ?? "",
        thumbnailURL: thumbnail, durationSeconds: live ? nil : duration, viewCountText: meta.views,
        publishedText: meta.published, isLive: live, isUpcoming: upcoming
      ))
    default:
      // Movies, shows and other storefront lockup types are not playable videos.
      return nil
    }
  }

  // MARK: Legacy renderers

  static func legacyVideo(_ v: JSONValue) -> VideoSummary? {
    guard let id = v["videoId"]?.string, let title = (v["title"] ?? v["headline"])?.text, !title.isEmpty else { return nil }
    let owner = v["ownerText"] ?? v["longBylineText"] ?? v["shortBylineText"]
    let ownerRun = owner?["runs", "0"]
    let badges = v["badges"]?.array ?? []
    let isLive = badges.contains { $0["metadataBadgeRenderer", "style"]?.string == "BADGE_STYLE_TYPE_LIVE_NOW" }
      || (v["thumbnailOverlays"]?.array ?? []).contains {
        $0["thumbnailOverlayTimeStatusRenderer", "style"]?.string == "LIVE"
      }
    let lengthText = v["lengthText"]?.text
      ?? (v["thumbnailOverlays"]?.array ?? []).lazy.compactMap { $0["thumbnailOverlayTimeStatusRenderer", "text"]?.text }.first
    var views = v["viewCountText"]?.text ?? v["shortViewCountText"]?.text
    var published = v["publishedTimeText"]?.text
    // playlistVideoRenderer packs both into videoInfo runs ("1.2M views", " • ", "3 years ago").
    if views == nil || published == nil, let info = v["videoInfo", "runs"]?.array {
      for run in info {
        guard let text = run["text"]?.string else { continue }
        switch classify(text) {
        case .views: views = views ?? text
        case .published: published = published ?? text
        default: break
        }
      }
    }
    return VideoSummary(
      videoID: id,
      title: title,
      channelID: ownerRun?["navigationEndpoint", "browseEndpoint", "browseId"]?.string ?? "",
      channelName: ownerRun?["text"]?.string ?? owner?.text ?? "",
      thumbnailURL: v["thumbnail"]?.firstThumbnailURL(),
      durationSeconds: isLive ? nil : lengthText.flatMap(parseDurationText) ?? v["lengthSeconds"]?.int,
      viewCountText: views,
      publishedText: published,
      isLive: isLive,
      isUpcoming: v["upcomingEventData"] != nil
    )
  }

  static func legacyPlaylist(_ v: JSONValue) -> PlaylistSummary? {
    guard let id = v["playlistId"]?.string, let title = v["title"]?.text else { return nil }
    let thumbnail = v["thumbnails", "0"]?.firstThumbnailURL() ?? v["thumbnail"]?.firstThumbnailURL()
      ?? v["thumbnailRenderer", "playlistVideoThumbnailRenderer", "thumbnail"]?.firstThumbnailURL()
    let count = v["videoCountText"]?.text ?? v["videoCountShortText"]?.text ?? v["videoCount"]?.string.map { "\($0) videos" }
    return PlaylistSummary(
      playlistID: id, title: title, thumbnailURL: thumbnail, videoCountText: count,
      author: (v["longBylineText"] ?? v["shortBylineText"])?.text ?? ""
    )
  }

  static func legacyChannel(_ v: JSONValue) -> ChannelSummary? {
    guard let id = v["channelId"]?.string, let title = v["title"]?.text else { return nil }
    var subscribers: String?
    var handle = ""
    for text in [v["subscriberCountText"]?.text, v["videoCountText"]?.text].compactMap({ $0 }) {
      if text.hasPrefix("@") { handle = text } else if classify(text) == .subscribers { subscribers = text }
    }
    return ChannelSummary(
      channelID: id, title: title, thumbnailURL: v["thumbnail"]?.firstThumbnailURL(),
      subscriberText: subscribers, handle: handle
    )
  }
}
