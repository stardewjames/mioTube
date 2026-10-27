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
  let images: ImagePipeline
  let settings: Settings
  let progress: WatchProgressStore
  let actions: AccountActions
  let account: AccountViewModel
  let diagnostics: DiagnosticsState
  let coordinator: PlaybackCoordinator
  /// Bumped when the account changes so feeds reload.
  private(set) var sessionRevision = 0

  private init() {
    guard let catalog = try? ProfileCatalog.bundled() else {
      preconditionFailure("ClientProfiles.json missing from the MioTubeCore bundle")
    }
    self.catalog = catalog
    let transport = URLSessionTransport()
    self.transport = transport
    configProvider = InnertubeConfigProvider(transport: transport, userAgent: catalog.metadata.userAgent ?? "")
    sessionStore = KeychainSessionStore()
    client = InnertubeClient(transport: transport, catalog: catalog, session: sessionStore, config: configProvider)
    resolver = StreamResolver(client: client, catalog: catalog)
    sponsorBlock = SponsorBlockClient(transport: transport, cache: SponsorBlockCache())
    feedCache = FeedCache(directory: FeedCache.defaultDirectory())
    feedLoader = FeedLoader(client: client, cache: feedCache)
    suggestions = SearchSuggestions(transport: transport, hl: client.locale.hl)
    images = ImagePipeline()
    settings = Settings()
    progress = WatchProgressStore(fileURL: WatchProgressStore.defaultFileURL())
    actions = AccountActions(client: client)
    account = AccountViewModel(store: sessionStore, actions: actions, cache: feedCache)
    diagnostics = DiagnosticsState(settings: settings)
    coordinator = PlaybackCoordinator(
      resolver: resolver, client: client, sponsorBlock: sponsorBlock, transport: transport,
      settings: settings, progress: progress, images: images
    )
    account.onSessionChange = { [weak self] in
      guard let self else { return }
      sessionRevision += 1
      Task { await self.resolverReset() }
    }
  }

  private func resolverReset() async {
    if let id = coordinator.current?.video.videoID { await resolver.invalidate(videoID: id) }
  }

  /// Launch work that must not block first frame.
  func start() {
    coordinator.activateRemoteCommands()
    Task { await account.restore() }
    Task { _ = await configProvider.config() }
  }
}

extension EnvironmentValues {
  /// Shared namespace for card → watch zoom transitions.
  @Entry var zoomNamespace: Namespace.ID?
}
