import Foundation

/// Cache-first loading and continuation paging for every feed screen.
public struct FeedLoader: Sendable {
  public let client: InnertubeClient
  public let cache: FeedCache
  public let adFilter: AdFilter
  /// Signed-out `FEwhat_to_watch` is an empty "Try searching" nudge for fresh visitors; these
  /// YouTube destination channels (Music, Live, Sports, News) fill Home instead.
  public let homeFallbackBrowseIDs: [String]

  public static let defaultHomeFallback = [
    "UC-9-kyTW8ZkZNDHQJ6FgpwQ", "UC4R8DWoMoI7CAwX8_LjQHig", "UCEgdi0XIXXZ-qJOFPf4JSKw", "UCYfdidRxbB8Qhf0Nx7ioOYw",
  ]

  public init(
    client: InnertubeClient, cache: FeedCache, adFilter: AdFilter = .init(),
    homeFallbackBrowseIDs: [String] = FeedLoader.defaultHomeFallback
  ) {
    self.client = client
    self.cache = cache
    self.adFilter = adFilter
    self.homeFallbackBrowseIDs = homeFallbackBrowseIDs
  }

  /// Cached copy when present (no network), otherwise fetches and replaces page 0.
  public func load(_ key: FeedKey, forceRefresh: Bool) async throws -> FeedPage {
    if !forceRefresh, let cached = await cache.page(for: key) { return cached }
    let (endpoint, page) = try await fetchFirstPage(key)
    await cache.store(page, for: key, endpoint: endpoint)
    return page
  }

  /// Cached page without touching the network (stale-while-revalidate first paint).
  public func cached(_ key: FeedKey) async -> FeedPage? {
    await cache.page(for: key)
  }

  /// Fetches the next continuation page, appends it to the cache and returns it.
  /// Nil when the feed has no further pages.
  public func nextPage(_ key: FeedKey) async throws -> FeedPage? {
    guard let token = await cache.continuation(for: key) else { return nil }
    let endpoint = await cache.endpoint(for: key) ?? "browse"
    let json = try await client.post(endpoint, ["continuation": .string(token)])
    let page = FeedParser.parse(json, adFilter: adFilter)
    await cache.append(page, to: key)
    return page
  }

  // MARK: Requests

  func fetchFirstPage(_ key: FeedKey) async throws -> (String, FeedPage) {
    switch key {
    case .home:
      let page = try await browse(["browseId": "FEwhat_to_watch"])
      if page.items.isEmpty, !homeFallbackBrowseIDs.isEmpty {
        return ("browse", await homeFallback(notice: page.notice, droppedAds: page.droppedAds))
      }
      return ("browse", page)
    case .subscriptions:
      return ("browse", try await browse(["browseId": "FEsubscriptions"]))
    case .history:
      return ("browse", try await browse(["browseId": "FEhistory"]))
    case .library:
      return ("browse", try await browse(["browseId": "FElibrary"]))
    case .playlist(let id):
      return ("browse", try await browse(["browseId": .string(id.hasPrefix("VL") ? id : "VL\(id)")]))
    case .channel(let id, let tab):
      let landing = try await browse(["browseId": .string(id)])
      guard tab != .home,
            let target = landing.tabs.first(where: { $0.title.caseInsensitiveCompare(tab.rawValue) == .orderedSame }),
            !target.isSelected, let params = target.params
      else { return ("browse", landing) }
      var page = try await browse(["browseId": .string(id), "params": .string(params)])
      if page.header == nil { page.header = landing.header }
      if page.tabs.isEmpty { page.tabs = landing.tabs }
      return ("browse", page)
    case .search(let query, let filter):
      let body: JSONValue
      switch filter {
      case .continuation(let token)?: body = ["continuation": .string(token)]
      case .params(let params)?: body = ["query": .string(query), "params": .string(params)]
      case nil: body = ["query": .string(query)]
      }
      var page = FeedParser.parse(try await client.post("search", body), adFilter: adFilter)
      if page.chips.isEmpty, filter != nil, let base = await cache.page(for: .search(query)) {
        page.chips = base.chips.map {
          SearchChip(title: $0.title, params: $0.params, token: $0.token, isSelected: $0.filter == filter)
        }
      }
      return ("search", page)
    }
  }

  private func browse(_ body: JSONValue) async throws -> FeedPage {
    FeedParser.parse(try await client.post("browse", body), adFilter: adFilter)
  }

  private func homeFallback(notice: String?, droppedAds: Int) async -> FeedPage {
    let pages = await withTaskGroup(of: (Int, FeedPage?).self) { group in
      for (index, id) in homeFallbackBrowseIDs.enumerated() {
        group.addTask { (index, try? await browse(["browseId": .string(id)])) }
      }
      var results: [(Int, FeedPage)] = []
      for await (index, page) in group {
        if let page { results.append((index, page)) }
      }
      return results.sorted { $0.0 < $1.0 }.map(\.1)
    }
    let sections = pages.flatMap { page in
      page.sections.map { section in
        FeedSection(
          id: section.id,
          title: section.title ?? page.header?.title,
          items: section.items,
          continuation: nil
        )
      }
    }
    return FeedPage(
      sections: sections, continuation: nil,
      droppedAds: droppedAds + pages.reduce(0) { $0 + $1.droppedAds },
      notice: notice
    )
  }
}

/// Google's search-suggest endpoint. Never throws: failures return no suggestions.
public struct SearchSuggestions: Sendable {
  public let transport: any HTTPTransport
  public let hl: String

  public init(transport: any HTTPTransport, hl: String) {
    self.transport = transport
    self.hl = hl
  }

  public func suggestions(for query: String) async -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }
    var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")!
    components.queryItems = [
      .init(name: "client", value: "firefox"), .init(name: "ds", value: "yt"),
      .init(name: "hl", value: hl), .init(name: "q", value: trimmed),
    ]
    guard let url = components.url,
          let response = try? await transport.send(HTTPRequest(url: url, timeout: 5)),
          let json = try? JSONValue.decode(response.data)
    else { return [] }
    return Self.parse(json)
  }

  /// `["query", ["s1", "s2", ...], ...]`
  public static func parse(_ json: JSONValue) -> [String] {
    json["1"]?.array?.compactMap(\.string) ?? []
  }
}
