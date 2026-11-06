import Foundation
import MioTubeCore
import Observation
import SwiftUI

/// Values surfaced on the Diagnostics screen.
@Observable
final class DiagnosticsState {
  private(set) var lastFeedDroppedAds = 0
  private(set) var lastFeedName = ""
  private(set) var lastWatchDroppedAds = 0
  @ObservationIgnored private let settings: Settings

  init(settings: Settings) {
    self.settings = settings
  }

  func record(feed: FeedKey, droppedAds: Int) {
    lastFeedDroppedAds = droppedAds
    lastFeedName = feed.storageID
    if droppedAds > 0 { settings.blockedAdsTotal += droppedAds }
  }

  func record(watchDroppedAds: Int) {
    lastWatchDroppedAds = watchDroppedAds
    if watchDroppedAds > 0 { settings.blockedAdsTotal += watchDroppedAds }
  }
}

/// Synchronous, observable mirror of `WatchProgressStore` for feed rendering.
@Observable
final class WatchProgressIndex {
  private(set) var entries: [String: WatchProgress] = [:]
  @ObservationIgnored private let store: WatchProgressStore

  init(store: WatchProgressStore) {
    self.store = store
  }

  func refresh() async {
    entries = await store.snapshot()
  }

  func entry(for videoID: String) -> WatchProgress? {
    entries[videoID]
  }

  func record(videoID: String, position: Double, duration: Double, at date: Date = Date()) {
    guard position.isFinite, duration.isFinite, duration > 0 else { return }
    entries[videoID] = WatchProgress(position: position, duration: duration, updatedAt: date)
  }
}

/// Composition root, injected with `.environment(env)`.
@Observable
final class AppEnvironment {
  static let shared = AppEnvironment()

  let catalog: ProfileCatalog
  let transport: URLSessionTransport
  let configProvider: InnertubeConfigProvider
  let sessionStore: KeychainSessionStore
  let client: InnertubeClient
  let resolver: StreamResolver
  let sponsorBlock: SponsorBlockClient
  let feedCache: FeedCache
  let feedLoader: FeedLoader
  let suggestions: SearchSuggestions
  let searchHistory: SearchHistory
  let images: ImagePipeline
  let settings: Settings
  let progress: WatchProgressStore
  let watchProgress: WatchProgressIndex
  let actions: AccountActions
  let account: AccountViewModel
  let diagnostics: DiagnosticsState
  let coordinator: PlaybackCoordinator
  /// Bumped when the account changes so feeds reload.
  private(set) var sessionRevision = 0
  private(set) var historyRevision = 0
  /// Home tab's navigation stack. Deep-linked playlists/channels are appended here;
  /// `RootView` switches to the Home tab whenever it changes.
  var homePath: [Route] = []

  private init() {
    guard let catalog = try? ProfileCatalog.bundled() else {
      preconditionFailure("ClientProfiles.json missing from the MioTubeCore bundle")
    }
    self.catalog = catalog
    let transport = URLSessionTransport()
    self.transport = transport
    configProvider = InnertubeConfigProvider(transport: transport, userAgent: catalog.metadata.httpUserAgent ?? "")
    sessionStore = KeychainSessionStore()
    client = InnertubeClient(transport: transport, catalog: catalog, session: sessionStore, config: configProvider)
    resolver = StreamResolver(client: client, catalog: catalog)
    sponsorBlock = SponsorBlockClient(transport: transport, cache: SponsorBlockCache())
    feedCache = FeedCache(directory: FeedCache.defaultDirectory())
    feedLoader = FeedLoader(client: client, cache: feedCache)
    suggestions = SearchSuggestions(transport: transport, hl: client.locale.hl, gl: client.locale.gl)
    searchHistory = SearchHistory()
    images = ImagePipeline()
    settings = Settings()
    progress = WatchProgressStore(fileURL: WatchProgressStore.defaultFileURL())
    watchProgress = WatchProgressIndex(store: progress)
    actions = AccountActions(client: client)
    account = AccountViewModel(store: sessionStore, actions: actions, cache: feedCache)
    diagnostics = DiagnosticsState(settings: settings)
    coordinator = PlaybackCoordinator(
      resolver: resolver, client: client, sponsorBlock: sponsorBlock, transport: transport,
      settings: settings, progress: progress, watchProgress: watchProgress, images: images
    )
    account.onSessionChange = { [weak self] in
      guard let self else { return }
      sessionRevision += 1
      coordinator.accountDidChange()
    }
  }


  func watchHistoryDidChange() async {
    await feedCache.remove(.history)
    historyRevision &+= 1
  }

  /// Launch work that must not block first frame.
  func start() {
    coordinator.activateRemoteCommands()
    Task { await account.restore() }
    Task { await watchProgress.refresh() }
    Task { _ = await configProvider.config() }
  }

  /// Opens a YouTube link handed to the app (`youtube://` deep link or web URL).
  /// Returns false when the URL isn't a YouTube link.
  @discardableResult
  func open(_ url: URL) -> Bool {
    guard let link = YouTubeLink(url: url) else { return false }
    open(link)
    return true
  }

  /// Videos play immediately; playlists and channels are pushed onto the Home
  /// tab's stack (`homePath`), which `RootView` switches into view.
  func open(_ link: YouTubeLink) {
    switch link {
    case .video(let id):
      // Placeholder summary: the watch screen fills in title/channel from the `next` response.
      coordinator.play(VideoSummary(
        videoID: id, title: "", channelID: "", channelName: "", thumbnailURL: nil,
        durationSeconds: nil, viewCountText: nil, publishedText: nil, isLive: false, isUpcoming: false
      ))
      // No feed card for this video is registered in the zoom namespace, so retarget the
      // transition to the mini player — the same source the mini-player tap opens from.
      coordinator.watchZoomSource = PlaybackCoordinator.miniPlayerZoomID
    case .playlist(let id):
      homePath.append(.playlist(id: id, title: ""))
    case .channel(let id):
      homePath.append(.channel(id: id, title: id.hasPrefix("@") ? id : ""))
    }
  }
}

extension EnvironmentValues {
  /// Shared namespace for card → watch zoom transitions.
  @Entry var zoomNamespace: Namespace.ID? = nil
}
