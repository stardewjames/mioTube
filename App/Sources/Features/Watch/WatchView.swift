import MioTubeCore
import SwiftUI

/// Video surface on top (16:9, or the whole screen in fullscreen), info stack below.
struct WatchView: View {
  @Environment(AppEnvironment.self) private var env
  @Environment(\.zoomNamespace) private var namespace

  var body: some View {
    @Bindable var coordinator = env.coordinator
    GeometryReader { proxy in
      VStack(spacing: 0) {
        VideoSurface()
          .frame(
            width: proxy.size.width,
            height: coordinator.isFullscreen ? proxy.size.height : proxy.size.width * 9 / 16
          )
        if !coordinator.isFullscreen {
          NavigationStack {
            ScrollView {
              WatchInfoPanel()
                .padding(16)
            }
            .scrollEdgeEffectStyle(.soft, for: .top)
            .toolbarVisibility(.hidden, for: .navigationBar)
            .withRoutes()
          }
        }
      }
    }
    .background(coordinator.isFullscreen ? Color.black : Color(.systemBackground))
    .ignoresSafeArea(edges: coordinator.isFullscreen ? .all : [])
    .statusBarHidden(coordinator.isFullscreen)
    .persistentSystemOverlays(coordinator.isFullscreen ? .hidden : .automatic)
    // Also disables the zoom transition's drag-to-dismiss; the player handles vertical swipes.
    .interactiveDismissDisabled()
    .modifier(ZoomDestination(id: coordinator.watchZoomSource, namespace: namespace))
    .onAppear { coordinator.watchScreenDidAppear() }
    .task {
      // Open from the tapped card, but once on screen retarget the zoom so closing shrinks
      // the player into the mini-player instead of back to the feed card.
      try? await Task.sleep(for: .milliseconds(600))
      coordinator.watchZoomSource = PlaybackCoordinator.miniPlayerZoomID
    }
    .sheet(item: $coordinator.failure) { failure in
      PlaybackFailureSheet(failure: failure)
    }
  }
}

private struct ZoomDestination: ViewModifier {
  let id: String?
  let namespace: Namespace.ID?

  func body(content: Content) -> some View {
    if let id, let namespace {
      content.navigationTransition(.zoom(sourceID: id, in: namespace))
    } else {
      content
    }
  }
}

/// `PlayerLayerView` + overlay + captions.
struct VideoSurface: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    ZStack(alignment: .bottom) {
      Color.black
      PlayerLayerView(engine: env.coordinator.engine, isActive: env.coordinator.isWatchPresented)
      if case .failed = env.coordinator.phase {
        RemoteImage(url: env.coordinator.current?.video.bestThumbnailURL)
          .overlay(Color.black.opacity(0.5))
          .allowsHitTesting(false)
      }
      CaptionOverlay()
      PlayerOverlay()
    }
    .clipped()
  }
}

extension PlaybackFailure: @retroactive Identifiable {
  nonisolated public var id: String { reasons.map { "\($0.profile):\($0.reason)" }.joined(separator: "|") }
}

/// Lists why each client profile could not play the video.
struct PlaybackFailureSheet: View {
  let failure: PlaybackFailure
  @Environment(AppEnvironment.self) private var env
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      List {
        Section {
          Text("YouTube did not return a playable stream for any client profile. This is usually temporary, or the video is restricted.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Section("Per-profile reasons") {
          ForEach(failure.reasons, id: \.self) { reason in
            VStack(alignment: .leading, spacing: 2) {
              Text(reason.profile).font(.subheadline.monospaced().weight(.semibold))
              Text(reason.reason).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }
      .navigationTitle("Playback unavailable")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
        ToolbarItem(placement: .primaryAction) {
          Button("Retry") {
            dismiss()
            env.coordinator.retry()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}
