import Foundation

/// Cache-first loading and continuation paging for every feed screen.
public struct FeedLoader: Sendable {
  public let client: InnertubeClient
  public let cache: FeedCache
  public let adFilter: AdFilter

  public init(client: InnertubeClient, cache: FeedCache, adFilter: AdFilter = .init()) {
    self.client = client
    self.cache = cache
    self.adFilter = adFilter
  }

  /// Cached copy when present (no network), otherwise fetches and replaces page 0.
  public func load(_ key: FeedKey, forceRefresh: Bool) async throws -> FeedPage {
    if !forceRefresh, let cached = await cached(key) { return cached }
    let (endpoint, page) = try await fetchFirstPage(key)
    await cache.store(page, for: key, endpoint: endpoint)
    return page
  }

  /// Cached page without touching the network (stale-while-revalidate first paint).
  /// Home snapshots written before special-section filtering are cleaned on read.
  public func cached(_ key: FeedKey) async -> FeedPage? {
    guard let page = await cache.page(for: key) else { return nil }
    return key == .home ? page.removingSpecialSections() : page
  }

  /// Fetches the next continuation page, appends it to the cache and returns it.
  /// Nil when the feed has no further pages.
  public func nextPage(_ key: FeedKey) async throws -> FeedPage? {
    guard let token = await cache.continuation(for: key) else { return nil }
    let endpoint = await cache.endpoint(for: key) ?? "browse"
    let json = try await client.post(endpoint, ["continuation": .string(token)])
    let parsed = try parsePage(json)
    let page = key == .home ? parsed.removingSpecialSections() : parsed
    await cache.append(page, to: key)
    return page
  }

  // MARK: Requests

  func fetchFirstPage(_ key: FeedKey) async throws -> (String, FeedPage) {
    switch key {
    case .home:
      return ("browse", try await browse(["browseId": "FEwhat_to_watch"]).removingSpecialSections())
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
      guard tab != .home else { return ("browse", landing) }
      guard let target = landing.tabs.first(where: {
        guard let raw = $0.navigationURL, let url = URL(string: raw) else {
          return $0.title.caseInsensitiveCompare(tab.rawValue) == .orderedSame
        }
        return url.lastPathComponent == (tab == .live ? "streams" : tab.rawValue.lowercased())
      }) else {
        throw MioTubeError.invalidResponse("This channel does not provide the requested tab.")
      }
      if target.isSelected { return ("browse", landing) }
      guard let params = target.params else {
        throw MioTubeError.invalidResponse("YouTube did not provide a channel tab endpoint.")
      }
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
      var page = try parsePage(try await client.post("search", body))
      if page.chips.isEmpty, filter != nil, let base = await cache.page(for: .search(query)) {
        page.chips = base.chips.map {
          SearchChip(title: $0.title, params: $0.params, token: $0.token, isSelected: $0.filter == filter)
        }
      }
      return ("search", page)
    }
  }

  private func browse(_ body: JSONValue) async throws -> FeedPage {
    try parsePage(try await client.post("browse", body))
  }

  private func parsePage(_ json: JSONValue) throws -> FeedPage {
    for alert in json["alerts"]?.array ?? [] {
      if let renderer = alert["alertRenderer"], renderer["type"]?.string == "ERROR" {
        throw MioTubeError.invalidResponse(renderer["text"]?.text ?? "YouTube could not load this feed.")
      }
    }
    return FeedParser.parse(json, adFilter: adFilter)
  }
}

/// Google's search-suggest endpoint. Never throws: failures return no suggestions.
public struct SearchSuggestions: Sendable {
  public let transport: any HTTPTransport
  public let hl: String
  public let gl: String

  public init(transport: any HTTPTransport, hl: String, gl: String = "US") {
    self.transport = transport
    self.hl = hl
    self.gl = gl
  }

  public func suggestions(for query: String) async -> [String] {
    let trimmed = query.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return [] }
    var components = URLComponents(string: "https://www.youtube.com/complete/search")!
    components.queryItems = [
      .init(name: "client", value: "youtube"), .init(name: "gs_ri", value: "youtube"),
      .init(name: "ds", value: "yt"), .init(name: "hl", value: hl),
      .init(name: "gl", value: gl), .init(name: "q", value: trimmed),
    ]
    guard let url = components.url,
          let response = try? await transport.send(HTTPRequest(url: url, timeout: 5)),
          (200..<300).contains(response.status),
          let json = Self.decode(response.data)
    else { return [] }
    return Self.parse(json)
  }

  /// The WEB endpoint returns a fixed JSONP wrapper and nested suggestion rows; never execute it.
  static func decode(_ data: Data) -> JSONValue? {
    guard var text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          text.hasPrefix("window.google.ac.h(") else { return nil }
    text.removeFirst("window.google.ac.h(".count)
    if text.hasSuffix(";") { text.removeLast() }
    guard text.hasSuffix(")") else { return nil }
    text.removeLast()
    return try? JSONValue.decode(Data(text.utf8))
  }

  /// `["query", [["suggestion", ...], ...], ...]`
  public static func parse(_ json: JSONValue) -> [String] {
    json["1"]?.array?.compactMap { $0["0"]?.string } ?? []
  }
}
