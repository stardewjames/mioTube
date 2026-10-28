import Foundation

public enum SearchFilter: Hashable, Sendable, Codable {
  /// Legacy `searchEndpoint.params` (also used for typed filters).
  case params(String)
  /// 2026 chips carry a `continuationCommand` token instead of params.
  case continuation(String)
}

extension SearchChip {
  public var filter: SearchFilter? {
    if let token { return .continuation(token) }
    if let params { return .params(params) }
    return nil
  }
}

public enum ChannelTabKind: String, Hashable, Sendable, Codable, CaseIterable {
  case home = "Home"
  case videos = "Videos"
  case live = "Live"
  case playlists = "Playlists"
}

public enum FeedKey: Hashable, Sendable, Codable {
  case home
  case subscriptions
  case history
  case library
  case search(String, SearchFilter? = nil)
  case channel(String, ChannelTabKind)
  case playlist(String)

  /// Stable identity used for the on-disk file name.
  public var storageID: String {
    switch self {
    case .home: "home"
    case .subscriptions: "subscriptions"
    case .history: "history"
    case .library: "library"
    case .search(let query, let filter):
      switch filter {
      case .params(let p)?: "search:\(query):p:\(p)"
      case .continuation(let t)?: "search:\(query):c:\(t)"
      case nil: "search:\(query)"
      }
    case .channel(let id, let tab): "channel:\(id):\(tab.rawValue)"
    case .playlist(let id): "playlist:\(id)"
    }
  }

  var fileName: String { String(sha256Hex(storageID).prefix(24)) + ".json" }

  /// Account-bound feeds; cleared on sign-in/out.
  public var isPersonal: Bool {
    switch self {
    case .home, .subscriptions, .history, .library: true
    default: false
    }
  }
}

/// Snapshot cache: one JSON file per key, written atomically, loaded lazily.
public actor FeedCache {
  public static let maxPersistedPages = 6

  struct Entry: Codable {
    var pages: [FeedPage]
    /// InnerTube endpoint that produced the pages; continuations must go back to it.
    var endpoint: String
  }

  private let directory: URL?
  private var entries: [FeedKey: Entry] = [:]
  private var loaded: Set<FeedKey> = []

  /// `directory == nil` keeps the cache in memory only (tests).
  public init(directory: URL?) {
    self.directory = directory
  }

  public static func defaultDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("MioTube/feeds", isDirectory: true)
  }

  /// All cached pages merged into one (sections concatenated, last continuation).
  public func page(for key: FeedKey) -> FeedPage? {
    guard let entry = entry(key), let first = entry.pages.first else { return nil }
    if entry.pages.count == 1 { return first }
    var merged = FeedPage(
      sections: entry.pages.flatMap(\.sections),
      continuation: entry.pages.last?.continuation,
      droppedAds: entry.pages.reduce(0) { $0 + $1.droppedAds },
      chips: first.chips, header: first.header, tabs: first.tabs
    )
    merged.notice = first.notice
    return merged
  }

  public func endpoint(for key: FeedKey) -> String? { entry(key)?.endpoint }

  public func continuation(for key: FeedKey) -> String? { entry(key)?.pages.last?.continuation }

  /// Replaces everything for `key` with a fresh first page.
  public func store(_ page: FeedPage, for key: FeedKey, endpoint: String = "browse") {
    let entry = Entry(pages: [page], endpoint: endpoint)
    entries[key] = entry
    loaded.insert(key)
    persist(entry, for: key)
  }

  public func append(_ page: FeedPage, to key: FeedKey) {
    guard var entry = entry(key) else { return }
    entry.pages.append(page)
    entries[key] = entry
    if entry.pages.count <= Self.maxPersistedPages { persist(entry, for: key) }
  }

  public func remove(_ key: FeedKey) {
    entries[key] = nil
    loaded.insert(key)
    if let url = fileURL(key) { try? FileManager.default.removeItem(at: url) }
  }

  public func clearAll() {
    entries = [:]
    loaded = []
    if let directory { try? FileManager.default.removeItem(at: directory) }
  }

  public func clearPersonal() {
    for key in [FeedKey.home, .subscriptions, .history, .library] { remove(key) }
  }

  // MARK: Disk

  private func entry(_ key: FeedKey) -> Entry? {
    if !loaded.contains(key) {
      loaded.insert(key)
      if let url = fileURL(key), let data = try? Data(contentsOf: url),
         let entry = try? JSONDecoder().decode(Entry.self, from: data) {
        entries[key] = entry
      }
    }
    return entries[key]
  }

  private func fileURL(_ key: FeedKey) -> URL? {
    directory?.appendingPathComponent(key.fileName)
  }

  private func persist(_ entry: Entry, for key: FeedKey) {
    guard let directory, let url = fileURL(key) else { return }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(entry)
      try data.write(to: url, options: .atomic)
    } catch {
      // Cache is best-effort; the network copy is authoritative.
    }
  }
}
