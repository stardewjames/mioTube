import MioTubeCore
import Observation
import SwiftUI

enum FeedStyle {
  case grid
  case list
}

enum Route: Hashable {
  case channel(id: String, title: String)
  case playlist(id: String, title: String)
  case feed(FeedKey, title: String)
  case settings
  case diagnostics
  case pasteCookies
}

/// Stale-while-revalidate state for one feed key.
@Observable
final class FeedModel {
  let key: FeedKey
  private(set) var page: FeedPage?
  private(set) var isLoading = false
  private(set) var isLoadingMore = false
  private(set) var error: String?
  private(set) var reachedEnd = false
  @ObservationIgnored private var loadedRevision = -1

  static let staleAfter: TimeInterval = 10 * 60

  init(key: FeedKey) {
    self.key = key
  }

  /// Cached page first (no network); network refresh when forced, missing or stale.
  func load(_ env: AppEnvironment, force: Bool = false) async {
    if force || loadedRevision != env.sessionRevision { reachedEnd = false }
    if !force, page == nil, let cached = await env.feedLoader.cached(key) {
      page = cached
    }
    let savedAt = await env.feedCache.savedAt(for: key)
    let stale = savedAt.map { Date().timeIntervalSince($0) > Self.staleAfter } ?? true
    let revisionChanged = loadedRevision != env.sessionRevision
    guard force || page == nil || stale || revisionChanged else { return }
    loadedRevision = env.sessionRevision
    isLoading = page == nil
    defer { isLoading = false }
    do {
      let fresh = try await env.feedLoader.load(key, forceRefresh: true)
      page = fresh
      error = nil
      reachedEnd = fresh.continuation == nil
      env.diagnostics.record(feed: key, droppedAds: fresh.droppedAds)
    } catch MioTubeError.unauthorized {
      env.account.markExpired()
      error = "Session expired — sign in again"
    } catch {
      if page == nil { self.error = Self.describe(error) }
    }
  }

  func loadMore(_ env: AppEnvironment) async {
    guard !isLoadingMore, !reachedEnd, page?.continuation != nil else { return }
    isLoadingMore = true
    defer { isLoadingMore = false }
    do {
      guard let next = try await env.feedLoader.nextPage(key) else {
        reachedEnd = true
        return
      }
      env.diagnostics.record(feed: key, droppedAds: next.droppedAds)
      page = await env.feedLoader.cached(key)
      reachedEnd = next.continuation == nil || next.items.isEmpty
    } catch {
      reachedEnd = true
    }
  }

  static func describe(_ error: any Error) -> String {
    switch error {
    case MioTubeError.transport(let message): message
    case MioTubeError.http(let status, _): "YouTube returned HTTP \(status)"
    case MioTubeError.notSignedIn: "Sign in to see this feed"
    default: error.localizedDescription
    }
  }
}

/// Section-aware grid of feed items with infinite scroll.
struct FeedScrollView<Header: View>: View {
  let model: FeedModel
  var style: FeedStyle = .grid
  @ViewBuilder var header: Header

  @Environment(AppEnvironment.self) private var env

  var body: some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 16, pinnedViews: []) {
        header
        if let page = model.page {
          ForEach(page.sections) { section in
            if let title = section.title {
              SectionHeader(title: title)
            }
            switch style {
            case .grid:
              LazyVGrid(columns: [GridItem(.adaptive(minimum: 340), spacing: 12)], spacing: 20) {
                items(section, in: page)
              }
            case .list:
              LazyVStack(alignment: .leading, spacing: 14) {
                items(section, in: page)
              }
            }
          }
          if model.isLoadingMore {
            ProgressView().frame(maxWidth: .infinity).padding()
          }
        } else if model.isLoading {
          ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
        } else if let error = model.error {
          ContentUnavailableView("Couldn't load", systemImage: "wifi.exclamationmark", description: Text(error))
            .padding(.top, 40)
        }
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 24)
    }
    .scrollEdgeEffectStyle(.soft, for: .top)
    .refreshable { await model.load(env, force: true) }
    .task(id: env.sessionRevision) { await model.load(env) }
  }

  @ViewBuilder
  private func items(_ section: FeedSection, in page: FeedPage) -> some View {
    let lastID = page.sections.last?.items.last?.id
    ForEach(section.items) { item in
      FeedItemView(item: item, queue: section.items.compactMap(\.video), style: style)
        .onAppear {
          if item.id == lastID { Task { await model.loadMore(env) } }
        }
    }
  }
}

extension FeedScrollView where Header == EmptyView {
  init(model: FeedModel, style: FeedStyle = .grid) {
    self.init(model: model, style: style) { EmptyView() }
  }
}

/// Tap target for any feed item: videos play, playlists/channels push.
struct FeedItemView: View {
  let item: FeedItem
  let queue: [VideoSummary]
  var style: FeedStyle = .grid

  @Environment(AppEnvironment.self) private var env
  @Environment(\.zoomNamespace) private var namespace

  var body: some View {
    switch item {
    case .video(let video):
      Button {
        env.coordinator.play(video, queue: queue)
      } label: {
        Group {
          if style == .grid {
            VideoCard(video: video).equatable()
          } else {
            VideoRow(video: video).equatable()
          }
        }
        .modifier(ZoomSource(id: video.videoID, namespace: namespace))
      }
      .buttonStyle(.plain)
      .contextMenu {
        Button("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") { env.coordinator.playNext(video) }
        if !video.channelID.isEmpty {
          NavigationLink(value: Route.channel(id: video.channelID, title: video.channelName)) {
            Label("Go to channel", systemImage: "person.crop.square")
          }
        }
        ShareLink(item: URL(string: "https://youtu.be/\(video.videoID)")!)
      }
    case .playlist(let playlist):
      NavigationLink(value: Route.playlist(id: playlist.playlistID, title: playlist.title)) {
        PlaylistCard(playlist: playlist)
      }
      .buttonStyle(.plain)
    case .channel(let channel):
      NavigationLink(value: Route.channel(id: channel.channelID, title: channel.title)) {
        ChannelRow(channel: channel)
      }
      .buttonStyle(.plain)
    }
  }
}

struct ZoomSource: ViewModifier {
  let id: String
  let namespace: Namespace.ID?

  func body(content: Content) -> some View {
    if let namespace {
      content.matchedTransitionSource(id: id, in: namespace)
    } else {
      content
    }
  }
}

/// Shared navigation destinations for every tab's stack.
struct RouteDestinations: ViewModifier {
  func body(content: Content) -> some View {
    content.navigationDestination(for: Route.self) { route in
      switch route {
      case .channel(let id, let title): ChannelView(channelID: id, title: title)
      case .playlist(let id, let title): PlaylistView(playlistID: id, title: title)
      case .feed(let key, let title): FeedScreen(key: key, title: title, style: .list)
      case .settings: SettingsView()
      case .diagnostics: DiagnosticsView()
      case .pasteCookies: PasteCookiesView()
      }
    }
  }
}

extension View {
  func withRoutes() -> some View { modifier(RouteDestinations()) }
}

/// A plain titled feed (History, Library, …).
struct FeedScreen: View {
  let title: String
  let style: FeedStyle
  @State private var model: FeedModel

  init(key: FeedKey, title: String, style: FeedStyle = .grid) {
    self.title = title
    self.style = style
    _model = State(initialValue: FeedModel(key: key))
  }

  var body: some View {
    FeedScrollView(model: model, style: style)
      .navigationTitle(title)
      .navigationBarTitleDisplayMode(.inline)
  }
}
