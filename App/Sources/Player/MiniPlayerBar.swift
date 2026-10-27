import MioTubeCore
import SwiftUI

/// Tab-bar bottom accessory: live video thumbnail, title, play/pause, close. The system draws
/// the accessory's Liquid Glass capsule, so no extra glass is layered on top.
struct MiniPlayerBar: View {
  @Environment(AppEnvironment.self) private var env
  @Environment(\.tabViewBottomAccessoryPlacement) private var placement
  @Environment(\.zoomNamespace) private var namespace

  var body: some View {
    let coordinator = env.coordinator
    if let item = coordinator.current {
      HStack(spacing: 10) {
        ZStack {
          RemoteImage(url: item.video.bestThumbnailURL)
          if coordinator.phase == .playing {
            PlayerLayerView(engine: coordinator.engine, isActive: !coordinator.isWatchPresented)
          }
        }
        .frame(width: 64, height: 36)
        .clipShape(.rect(cornerRadius: 6))
        .modifier(ZoomSource(id: PlaybackCoordinator.miniPlayerZoomID, namespace: namespace))

        VStack(alignment: .leading, spacing: 1) {
          Text(coordinator.info?.title ?? item.video.title)
            .font(.footnote.weight(.semibold))
            .lineLimit(1)
          if placement != .inline {
            Text(coordinator.info?.channel?.title ?? item.video.channelName)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }
        Spacer(minLength: 4)
        Button {
          coordinator.engine.togglePlayPause()
        } label: {
          Image(systemName: coordinator.engine.isPlaying ? "pause.fill" : "play.fill")
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 32, height: 32)
        }
        .accessibilityLabel(coordinator.engine.isPlaying ? "Pause" : "Play")
        if placement != .inline {
          Button {
            coordinator.close()
          } label: {
            Image(systemName: "xmark").frame(width: 28, height: 32)
          }
          .accessibilityLabel("Close player")
        }
      }
      .padding(.horizontal, 10)
      .frame(height: 56)
      .contentShape(.rect)
      .onTapGesture {
        coordinator.watchZoomSource = PlaybackCoordinator.miniPlayerZoomID
        coordinator.isWatchPresented = true
      }
      .buttonStyle(.plain)
    } else {
      HStack {
        Image(systemName: "play.rectangle").foregroundStyle(.secondary)
        Text("Not playing").font(.footnote).foregroundStyle(.secondary)
        Spacer()
      }
      .padding(.horizontal, 14)
    }
  }
}

/// `tabViewBottomAccessory(isEnabled:)` hides the bar when idle on iOS 26.1+; 26.0 always
/// shows it (with the idle "Not playing" state).
struct MiniPlayerAccessory: ViewModifier {
  let isEnabled: Bool

  func body(content: Content) -> some View {
    if #available(iOS 26.1, *) {
      content.tabViewBottomAccessory(isEnabled: isEnabled) { MiniPlayerBar() }
    } else {
      content.tabViewBottomAccessory { MiniPlayerBar() }
    }
  }
}
