import MioTubeCore
import SwiftUI

/// Glass controls over the video surface: scrubber with chapter ticks, transport, speed,
/// quality, captions, PiP, fullscreen. Auto-hides after 3 s of no touch while playing.
/// Swipe up enters fullscreen, swipe down leaves it.
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

  /// Control sizes scale with the surface: compact over the inline 16:9 video, larger in
  /// fullscreen.
  nonisolated struct Metrics {
    let chrome: CGFloat
    let chromeFont: Font
    let side: CGFloat
    let play: CGFloat
    let transportFont: Font
    let playFont: Font
    let spacing: CGFloat
    let padding: CGFloat
    let timeFont: Font

    static let inline = Metrics(
      chrome: 28, chromeFont: .footnote.weight(.semibold), side: 34, play: 48, transportFont: .callout,
      playFont: .title2, spacing: 18, padding: 8, timeFont: .caption2
    )
    static let fullscreen = Metrics(
      chrome: 40, chromeFont: .body.weight(.semibold), side: 50, play: 72, transportFont: .title3,
      playFont: .largeTitle, spacing: 32, padding: 20, timeFont: .caption
    )
  }

  private var coordinator: PlaybackCoordinator { env.coordinator }
  private var engine: PlayerEngine { env.coordinator.engine }
  private var metrics: Metrics { coordinator.isFullscreen ? .fullscreen : .inline }
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
          .simultaneousGesture(DragGesture(minimumDistance: 24).onEnded(swipe))

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
          controls
            .transition(.opacity)
        }

        if engine.isBuffering || coordinator.phase == .resolving || engine.status == .loading {
          ProgressView()
            .controlSize(coordinator.isFullscreen ? .large : .regular)
            .tint(.white)
            .allowsHitTesting(false)
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

  private var controls: some View {
    VStack(spacing: 0) {
      topBar
      Spacer(minLength: 0)
      // On failure transport is replaced by Retry (the surface shows the dimmed thumbnail).
      if isFailed {
        Button("Retry", systemImage: "arrow.clockwise") { coordinator.retry() }
          .buttonStyle(.glass)
      } else {
        transport
      }
      Spacer(minLength: 0)
      if !isFailed { scrubber }
    }
    .padding(metrics.padding)
    .background(
      LinearGradient(colors: [.black.opacity(0.4), .clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
        .allowsHitTesting(false)
    )
    .foregroundStyle(.white)
  }

  private func chromeIcon(_ name: String) -> some View {
    Image(systemName: name)
      .font(metrics.chromeFont)
      .frame(width: metrics.chrome, height: metrics.chrome)
  }

  private var topBar: some View {
    HStack(spacing: 8) {
      Button {
        if coordinator.isFullscreen { coordinator.isFullscreen = false } else { dismiss() }
      } label: {
        chromeIcon(coordinator.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "chevron.down")
      }
      .glassControl()
      .accessibilityLabel(coordinator.isFullscreen ? "Exit full screen" : "Minimize")

      if let chapter = coordinator.currentChapter {
        Text(chapter.title)
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .glassControl(interactive: false)
      }
      Spacer()
      GlassEffectContainer(spacing: 6) {
        HStack(spacing: 6) {
          captionsMenu
          settingsMenu
          if engine.isPictureInPicturePossible {
            Button { engine.togglePictureInPicture() } label: {
              chromeIcon(engine.isPiPActive ? "pip.exit" : "pip.enter")
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
      chromeIcon(coordinator.selectedCaption == nil ? "captions.bubble" : "captions.bubble.fill")
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
      chromeIcon("gearshape")
    }
    .glassControl()
    .accessibilityLabel("Playback settings")
  }

  private func transportButton(_ symbol: String, label: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
    Button {
      action()
      touch()
    } label: {
      Image(systemName: symbol)
        .font(metrics.transportFont)
        .frame(width: metrics.side, height: metrics.side)
    }
    .glassControl()
    .disabled(!enabled)
    .accessibilityLabel(label)
  }

  private var transport: some View {
    GlassEffectContainer(spacing: metrics.spacing) {
      HStack(spacing: metrics.spacing) {
        transportButton("backward.end.fill", label: "Previous") { coordinator.previous() }
        transportButton("gobackward.10", label: "Back 10 seconds") { engine.skip(by: -10) }

        Button { engine.togglePlayPause(); touch() } label: {
          Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
            .font(metrics.playFont)
            .contentTransition(.symbolEffect(.replace))
            .frame(width: metrics.play, height: metrics.play)
        }
        .glassControl()
        .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

        transportButton("goforward.10", label: "Forward 10 seconds") { engine.skip(by: 10) }
        transportButton("forward.end.fill", label: "Next", enabled: coordinator.hasNext) { coordinator.advance(.user) }
      }
    }
  }

  private var scrubber: some View {
    let duration = max(engine.duration, 1)
    let shown = scrubbing ? scrubValue : engine.position
    return VStack(spacing: coordinator.isFullscreen ? 6 : 0) {
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
        .controlSize(coordinator.isFullscreen ? .regular : .mini)
        .disabled(coordinator.info?.isLive == true || engine.duration <= 0)
        chapterTicks(duration: duration)
      }
      HStack(spacing: 6) {
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
          chromeIcon(coordinator.isFullscreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
        }
        .glassControl()
        .accessibilityLabel("Full screen")
      }
      .font(metrics.timeFont)
    }
  }

  /// Chapter markers as tappable ticks on the scrubber track.
  private func chapterTicks(duration: Double) -> some View {
    GeometryReader { proxy in
      ForEach(coordinator.info?.chapters.dropFirst() ?? [], id: \.startSeconds) { chapter in
        let x = proxy.size.width * chapter.startSeconds / duration
        Rectangle()
          .fill(.white.opacity(0.9))
          .frame(width: 2, height: coordinator.isFullscreen ? 8 : 6)
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
    .frame(height: coordinator.isFullscreen ? 24 : 18)
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
      .padding(.top, coordinator.isFullscreen ? 64 : 44)
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

  /// Vertical swipe: up enters fullscreen, down leaves it. Inline swipe-down stays with the
  /// sheet (it minimizes the player).
  private func swipe(_ value: DragGesture.Value) {
    let dy = value.translation.height
    guard abs(dy) > 50, abs(dy) > abs(value.translation.width) * 1.5 else { return }
    if dy < 0, !coordinator.isFullscreen {
      coordinator.isFullscreen = true
    } else if dy > 0, coordinator.isFullscreen {
      coordinator.isFullscreen = false
    }
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
      let fullscreen = env.coordinator.isFullscreen
      Text(text)
        .font(.system(size: env.settings.preferredCaptionSize * (fullscreen ? 1 : 0.8), weight: .medium))
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.black.opacity(0.6), in: .capsule)
        .padding(.bottom, fullscreen ? 72 : 40)
        .padding(.horizontal, 24)
        .allowsHitTesting(false)
        .transition(.opacity)
    }
  }
}
