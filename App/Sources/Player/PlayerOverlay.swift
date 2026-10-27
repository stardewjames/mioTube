import MioTubeCore
import SwiftUI

/// Glass controls over the video surface: scrubber with chapter ticks, transport, speed,
/// quality, captions, PiP, fullscreen. Auto-hides after 3 s of no touch while playing.
struct PlayerOverlay: View {
  @Environment(AppEnvironment.self) private var env
  @Environment(\.dismiss) private var dismiss
  @State private var controlsVisible = true
  @State private var interaction = 0
  @State private var scrubbing = false
  @State private var scrubValue: Double = 0
  @State private var seekHUD: SeekHUD?

  nonisolated struct SeekHUD: Equatable {
    let id = UUID()
    let forward: Bool
  }

  private var coordinator: PlaybackCoordinator { env.coordinator }
  private var engine: PlayerEngine { env.coordinator.engine }
  private var isFailed: Bool {
    if case .failed = coordinator.phase { return true }
    return false
  }

  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color.clear
          .contentShape(.rect)
          .gesture(
            SpatialTapGesture(count: 2)
              .onEnded { value in doubleTap(forward: value.location.x > proxy.size.width / 2) }
              .exclusively(before: TapGesture().onEnded { toggleControls() })
          )

        if let seekHUD {
          HStack {
            if seekHUD.forward { Spacer() }
            GlassToast(text: seekHUD.forward ? "+10 s" : "−10 s", systemImage: seekHUD.forward ? "goforward.10" : "gobackward.10")
              .padding(.horizontal, 32)
            if !seekHUD.forward { Spacer() }
          }
          .transition(.opacity)
          .allowsHitTesting(false)
        }

        if controlsVisible {
          controls(width: proxy.size.width)
            .transition(.opacity)
        }

        if engine.isBuffering || coordinator.phase == .resolving || engine.status == .loading {
          ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
        }
      }
      .overlay(alignment: .top) { sponsorToast }
    }
    .animation(.easeInOut(duration: 0.2), value: controlsVisible)
    .animation(.easeInOut(duration: 0.2), value: seekHUD)
    .task(id: interaction) {
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, engine.isPlaying, !scrubbing else { return }
      controlsVisible = false
    }
  }

  // MARK: Controls

  private func controls(width: CGFloat) -> some View {
    VStack(spacing: 0) {
      topBar
      Spacer(minLength: 0)
      // On failure transport is replaced by Retry (the surface shows the dimmed thumbnail).
      if isFailed {
        Button("Retry", systemImage: "arrow.clockwise") { coordinator.retry() }
          .buttonStyle(.glass)
          .controlSize(.large)
      } else {
        transport
      }
      Spacer(minLength: 0)
      if !isFailed { scrubber }
    }
    .padding(coordinator.isFullscreen ? 20 : 10)
    .background(
      LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    )
    .foregroundStyle(.white)
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      Button {
        if coordinator.isFullscreen { coordinator.isFullscreen = false } else { dismiss() }
      } label: {
        Image(systemName: coordinator.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "chevron.down")
          .frame(width: 36, height: 36)
      }
      .glassControl()
      .accessibilityLabel(coordinator.isFullscreen ? "Exit full screen" : "Minimize")

      if let chapter = coordinator.currentChapter {
        Text(chapter.title)
          .font(.caption.weight(.semibold))
          .lineLimit(1)
          .padding(.horizontal, 10)
          .padding(.vertical, 6)
          .glassControl(interactive: false)
      }
      Spacer()
      GlassEffectContainer(spacing: 8) {
        HStack(spacing: 8) {
          captionsMenu
          settingsMenu
          if engine.isPictureInPicturePossible {
            Button { engine.togglePictureInPicture() } label: {
              Image(systemName: engine.isPiPActive ? "pip.exit" : "pip.enter").frame(width: 36, height: 36)
            }
            .glassControl()
            .accessibilityLabel("Picture in Picture")
          }
        }
      }
    }
    .simultaneousGesture(TapGesture().onEnded { touch() })
  }

  private var captionsMenu: some View {
    Menu {
      Button {
        coordinator.selectCaption(nil)
      } label: {
        if coordinator.selectedCaption == nil { Label("Off", systemImage: "checkmark") } else { Text("Off") }
      }
      ForEach(coordinator.captionTracks) { track in
        Button {
          coordinator.selectCaption(track)
        } label: {
          let title = track.isAutomatic ? "\(track.name) (auto)" : track.name
          if coordinator.selectedCaption == track { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
      }
    } label: {
      Image(systemName: coordinator.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill")
        .frame(width: 36, height: 36)
    }
    .glassControl()
    .disabled(coordinator.captionTracks.isEmpty)
    .opacity(coordinator.captionTracks.isEmpty ? 0.4 : 1)
    .accessibilityLabel("Captions")
  }

  private var settingsMenu: some View {
    Menu {
      Picker("Speed", selection: Binding(get: { Double(engine.rate) }, set: { coordinator.setSpeed($0) })) {
        ForEach([0.5, 0.75, 1, 1.25, 1.5, 2], id: \.self) { speed in
          Text(speed == 1 ? "Normal" : "\(speed.formatted())×").tag(speed)
        }
      }
      .pickerStyle(.menu)
      Picker("Quality", selection: Binding(get: { coordinator.quality }, set: { coordinator.setQuality($0) })) {
        ForEach(QualityCap.allCases, id: \.self) { cap in
          Text(cap.label).tag(cap)
        }
      }
      .pickerStyle(.menu)
      Picker("Repeat", selection: Binding(get: { coordinator.repeatMode }, set: { coordinator.repeatMode = $0 })) {
        Text("Off").tag(RepeatMode.off)
        Text("Repeat one").tag(RepeatMode.one)
        Text("Repeat queue").tag(RepeatMode.all)
      }
      .pickerStyle(.menu)
      Button(engine.isMuted ? "Unmute" : "Mute", systemImage: engine.isMuted ? "speaker.wave.2" : "speaker.slash") {
        coordinator.toggleMute()
      }
    } label: {
      Image(systemName: "gearshape").frame(width: 36, height: 36)
    }
    .glassControl()
    .accessibilityLabel("Playback settings")
  }

  private var transport: some View {
    GlassEffectContainer(spacing: 24) {
      HStack(spacing: 28) {
        Button { coordinator.previous(); touch() } label: {
          Image(systemName: "backward.end.fill").font(.title3).frame(width: 48, height: 48)
        }
        .glassControl()
        .accessibilityLabel("Previous")

        Button { engine.togglePlayPause(); touch() } label: {
          Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
            .font(.largeTitle)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: 72, height: 72)
        }
        .glassControl()
        .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

        Button { coordinator.advance(.user); touch() } label: {
          Image(systemName: "forward.end.fill").font(.title3).frame(width: 48, height: 48)
        }
        .glassControl()
        .disabled(!coordinator.hasNext)
        .accessibilityLabel("Next")
      }
    }
  }

  private var scrubber: some View {
    let duration = max(engine.duration, 1)
    let shown = scrubbing ? scrubValue : engine.position
    return VStack(spacing: 6) {
      ZStack {
        Slider(
          value: Binding(get: { shown }, set: { scrubValue = $0 }),
          in: 0...duration,
          onEditingChanged: { editing in
            if editing {
              scrubValue = engine.position
              scrubbing = true
            } else {
              engine.seek(to: scrubValue, precise: true)
              scrubbing = false
            }
            touch()
          }
        )
        .tint(.red)
        .disabled(coordinator.info?.isLive == true || engine.duration <= 0)
        chapterTicks(duration: duration)
      }
      HStack {
        Text(Format.duration(shown)).monospacedDigit()
        if coordinator.fullVideoSponsored {
          Label("Sponsored video", systemImage: "dollarsign.circle").labelStyle(.iconOnly).foregroundStyle(.yellow)
        }
        Spacer()
        if coordinator.info?.isLive == true {
          LiveBadge()
        } else {
          Text(Format.duration(engine.duration)).monospacedDigit()
        }
        Button {
          coordinator.isFullscreen.toggle()
          touch()
        } label: {
          Image(systemName: coordinator.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
            .frame(width: 32, height: 32)
        }
        .glassControl()
        .accessibilityLabel("Full screen")
      }
      .font(.caption)
    }
  }

  /// Chapter markers as tappable ticks on the scrubber track.
  private func chapterTicks(duration: Double) -> some View {
    GeometryReader { proxy in
      ForEach(coordinator.info?.chapters.dropFirst() ?? [], id: \.startSeconds) { chapter in
        let x = proxy.size.width * chapter.startSeconds / duration
        Rectangle()
          .fill(.white.opacity(0.9))
          .frame(width: 2, height: 8)
          .padding(.horizontal, 6)
          .contentShape(.rect)
          .position(x: x, y: proxy.size.height / 2)
          .onTapGesture {
            engine.seek(to: chapter.startSeconds)
            touch()
          }
          .accessibilityLabel("Chapter: \(chapter.title)")
      }
    }
    .frame(height: 24)
  }

  @ViewBuilder
  private var sponsorToast: some View {
    if let toast = coordinator.sponsorToast {
      Group {
        switch toast.kind {
        case .skipped:
          GlassToast(text: "Skipped \(toast.segment.category.displayName.lowercased())", systemImage: "forward.fill") {
            Button("Undo") { coordinator.undoSkip() }
              .font(.subheadline.weight(.semibold))
          }
        case .muted:
          GlassToast(text: "Muted \(toast.segment.category.displayName.lowercased())", systemImage: "speaker.slash.fill")
        }
      }
      .padding(.top, 56)
      .transition(.move(edge: .top).combined(with: .opacity))
    }
  }

  // MARK: Interaction

  private func touch() {
    interaction += 1
  }

  private func toggleControls() {
    controlsVisible.toggle()
    touch()
  }

  private func doubleTap(forward: Bool) {
    engine.skip(by: forward ? 10 : -10)
    let hud = SeekHUD(forward: forward)
    seekHUD = hud
    Task {
      try? await Task.sleep(for: .milliseconds(700))
      if seekHUD == hud { seekHUD = nil }
    }
  }
}

/// VTT-driven captions above the scrubber area.
struct CaptionOverlay: View {
  @Environment(AppEnvironment.self) private var env

  var body: some View {
    if let text = env.coordinator.currentCaption {
      Text(text)
        .font(.system(size: env.settings.preferredCaptionSize, weight: .medium))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.black.opacity(0.6), in: .capsule)
        .padding(.bottom, 64)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }
}
