import Foundation

/// Turns any browse / search / continuation response into sections of items.
/// Two response generations coexist and both are supported: legacy `*Renderer` items and the
/// 2026 `lockupViewModel` items.
public enum FeedParser {
  public static func parse(_ json: JSONValue, adFilter: AdFilter = .init()) -> FeedPage {
    var root = json
    let dropped = adFilter.filter(&root)
    var builder = SectionBuilder()
    for container in contentRoots(root) {
      builder.visit(container)
    }
    builder.flush()
    var chips = builder.chips
    if let header = root["header"] {
      var headerBuilder = SectionBuilder()
      headerBuilder.collectChips(header)
      chips = headerBuilder.chips + chips
    }
    return FeedPage(
      sections: builder.sections,
      continuation: builder.pageContinuation,
      droppedAds: dropped + builder.droppedServiceContent,
      chips: uniqueChips(chips),
      header: parseHeader(root),
      tabs: parseTabs(root),
      notice: builder.sections.isEmpty ? notice(root) : nil
    )
  }

  // MARK: Roots

  static func contentRoots(_ root: JSONValue) -> [JSONValue] {
    var roots: [JSONValue] = []
    for columns in ["twoColumnBrowseResultsRenderer", "singleColumnBrowseResultsRenderer"] {
      if let tabs = root["contents", columns, "tabs"]?.array {
        let tabContents = tabs.compactMap { ($0["tabRenderer"] ?? $0["expandableTabRenderer"]) }
        let selected = tabContents.first { $0["selected"]?.bool == true && $0["content"] != nil }
          ?? tabContents.first { $0["content"] != nil }
        if let content = selected?["content"] { roots.append(content) }
      }
    }
    if let primary = root["contents", "twoColumnSearchResultsRenderer", "primaryContents"] { roots.append(primary) }
    if let list = root["contents", "sectionListRenderer"] { roots.append(list) }
    for key in ["onResponseReceivedActions", "onResponseReceivedEndpoints", "onResponseReceivedCommands"] {
      for action in root[key]?.array ?? [] {
        if let items = action["appendContinuationItemsAction", "continuationItems"] { roots.append(items) }
        if let items = action["reloadContinuationItemsCommand", "continuationItems"] { roots.append(items) }
      }
    }
    if let legacy = root["continuationContents"]?.object {
      for (_, value) in legacy { roots.append(value) }
    }
    return roots
  }

  // MARK: Builder

  struct SectionBuilder {
    var sections: [FeedSection] = []
    var chips: [SearchChip] = []
    var pageContinuation: String?
    /// Streaming-service items and shelves removed (Movies & TV, Primetime Channels, …).
    var droppedServiceContent = 0

    private var openTitle: String?
    private var openItems: [FeedItem] = []
    private var openIDs: Set<String> = []
    private var openContinuation: String?
    private var inShelf = false

    static let skipped: Set<String> = [
      "shortsLockupViewModel", "reelItemRenderer", "reelShelfRenderer", "gridShelfViewModel",
      "menu", "menuRenderer", "trackingParams", "navigationEndpoint", "thumbnailOverlays",
      "header", "loggingDirectives", "feedbackChips", "commandContext",
    ]

    static let shelves: Set<String> = ["richShelfRenderer", "shelfRenderer", "horizontalCardListRenderer"]

    mutating func visit(_ value: JSONValue) {
      switch value {
      case .array(let array):
        for element in array { visit(element) }
      case .object(let object):
        for key in object.keys.sorted(by: Self.memberOrder) {
          visitMember(key, object[key]!)
        }
      default:
        break
      }
    }

    /// Dictionary order is unspecified; visiting `contents` before `continuations` keeps the page
    /// continuation last, the rest is alphabetical for determinism.
    static func memberOrder(_ a: String, _ b: String) -> Bool {
      func rank(_ s: String) -> Int { s.hasPrefix("continuation") ? 1 : 0 }
      return rank(a) == rank(b) ? a < b : rank(a) < rank(b)
    }

    mutating func visitMember(_ key: String, _ value: JSONValue) {
      if Self.skipped.contains(key) {
        if key == "header" { collectChips(value) }
        return
      }
      switch ItemParser.parseFiltered(key, value) {
      case .item(let item):
        append(item)
        return
      case .excluded:
        droppedServiceContent += 1
        return
      case .notItem:
        break
      }
      switch key {
      case "continuationItemRenderer", "continuationItemViewModel":
        if let token = RendererTree.continuationToken(value) {
          if inShelf { openContinuation = token } else { pageContinuation = token }
        }
      case "chipCloudChipRenderer":
        if let chip = Self.chip(value) { chips.append(chip) }
      case let shelf where Self.shelves.contains(shelf) && !inShelf:
        let title = value["title"]?.text ?? value["header"]?.first(key: "title")?.text
        if StreamingContentFilter.isServiceShelf(title: title) {
          droppedServiceContent += 1
          return
        }
        flush()
        inShelf = true
        openTitle = title
        visit(value)
        flush()
        inShelf = false
      default:
        visit(value)
      }
    }

    mutating func append(_ item: FeedItem) {
      guard openIDs.insert(item.id).inserted else { return }
      openItems.append(item)
    }

    mutating func flush() {
      if !openItems.isEmpty {
        let first = openItems[0].id
        sections.append(FeedSection(
          id: "\(openTitle ?? "")#\(first)", title: openTitle, items: openItems, continuation: openContinuation
        ))
      }
      openTitle = nil
      openItems = []
      openIDs = []
      openContinuation = nil
    }

    mutating func collectChips(_ value: JSONValue) {
      RendererTree.walk(value) { key, renderer in
        if key == "chipCloudChipRenderer", let chip = Self.chip(renderer) { chips.append(chip) }
      }
    }

    static func chip(_ value: JSONValue) -> SearchChip? {
      guard let title = value["text"]?.text, !title.isEmpty else { return nil }
      let endpoint = value["navigationEndpoint"]
      return SearchChip(
        title: title,
        params: endpoint?["searchEndpoint", "params"]?.string,
        token: endpoint?["continuationCommand", "token"]?.string,
        isSelected: value["isSelected"]?.bool ?? false
      )
    }
  }

  static func uniqueChips(_ chips: [SearchChip]) -> [SearchChip] {
    var seen = Set<String>()
    return chips.filter { seen.insert($0.title).inserted }
  }

  // MARK: Header, tabs, notice

  static func parseHeader(_ root: JSONValue) -> FeedHeader? {
    guard let header = root["header"] else { return nil }
    if let model = header.first(key: "pageHeaderViewModel") {
      let title = model["title", "dynamicTextViewModel", "text", "content"]?.string
        ?? header.first(key: "pageTitle")?.string
      guard let title else { return nil }
      let parts = (model["metadata", "contentMetadataViewModel", "metadataRows"]?.array ?? [])
        .flatMap { $0["metadataParts"]?.array ?? [] }
        .compactMap { $0["text", "content"]?.string }
      return FeedHeader(
        title: title,
        subtitle: parts.isEmpty ? nil : parts.joined(separator: " · "),
        avatarURL: model["image", "decoratedAvatarViewModel", "avatar", "avatarViewModel", "image"]?.firstThumbnailURL(),
        bannerURL: model["banner", "imageBannerViewModel", "image"]?.firstThumbnailURL()
      )
    }
    if let legacy = header["c4TabbedHeaderRenderer"], let title = legacy["title"]?.text {
      return FeedHeader(
        title: title,
        subtitle: legacy["subscriberCountText"]?.text,
        avatarURL: legacy["avatar"]?.firstThumbnailURL(),
        bannerURL: legacy["banner"]?.firstThumbnailURL()
      )
    }
    if let title = header.first(key: "pageTitle")?.string {
      return FeedHeader(title: title, subtitle: nil, avatarURL: nil, bannerURL: nil)
    }
    return nil
  }

  static func parseTabs(_ root: JSONValue) -> [ChannelTab] {
    (root["contents", "twoColumnBrowseResultsRenderer", "tabs"]?.array ?? []).compactMap { tab in
      guard let renderer = tab["tabRenderer"], let title = renderer["title"]?.string else { return nil }
      return ChannelTab(
        title: title,
        params: renderer["endpoint", "browseEndpoint", "params"]?.string,
        isSelected: renderer["selected"]?.bool ?? false
      )
    }
  }

  static func notice(_ root: JSONValue) -> String? {
    guard let nudge = root["contents"]?.first(key: "feedNudgeRenderer") else { return nil }
    return nudge["title"]?.text
  }
}
