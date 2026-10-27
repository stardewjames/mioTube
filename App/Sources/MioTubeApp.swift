import MioTubeCore
import SwiftUI
import UIKit

@main
struct MioTubeApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @State private var env = AppEnvironment.shared

  var body: some Scene {
    WindowGroup {
      RootView()
        .environment(env)
        .preferredColorScheme(env.settings.appearance.colorScheme)
        .task { env.start() }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
  /// Portrait everywhere; landscape only while the player is fullscreen.
  func application(
    _ application: UIApplication,
    supportedInterfaceOrientationsFor window: UIWindow?
  ) -> UIInterfaceOrientationMask {
    PlaybackCoordinator.shared.isFullscreen ? [.landscapeLeft, .landscapeRight] : .portrait
  }
}

nonisolated enum RootTab: Hashable {
  case home, subscriptions, library, search
}

struct RootView: View {
  @Environment(AppEnvironment.self) private var env
  @Namespace private var zoomNamespace
  @State private var tab: RootTab = .home

  var body: some View {
    @Bindable var coordinator = env.coordinator
    @Bindable var account = env.account
    TabView(selection: $tab) {
      Tab("Home", systemImage: "house", value: RootTab.home) { HomeView() }
      Tab("Subscriptions", systemImage: "play.square.stack", value: RootTab.subscriptions) { SubscriptionsView() }
      Tab("Library", systemImage: "books.vertical", value: RootTab.library) { LibraryView() }
      Tab("Search", systemImage: "magnifyingglass", value: RootTab.search, role: .search) { SearchView() }
    }
    .tabBarMinimizeBehavior(.onScrollDown)
    .modifier(MiniPlayerAccessory(isEnabled: coordinator.current != nil))
    .environment(\.zoomNamespace, zoomNamespace)
    // A full-screen cover has no system pan-to-dismiss recognizer, so vertical swipes on the
    // video reach the player (up = fullscreen, down = minimize / leave fullscreen).
    .fullScreenCover(isPresented: $coordinator.isWatchPresented) {
      WatchView()
        .environment(env)
        .environment(\.zoomNamespace, zoomNamespace)
    }
    .sheet(isPresented: $account.isPresentingSignIn) {
      SignInSheet().environment(env)
    }
  }
}

extension AppearanceMode {
  var colorScheme: ColorScheme? {
    switch self {
    case .system: nil
    case .light: .light
    case .dark: .dark
    }
  }
}
