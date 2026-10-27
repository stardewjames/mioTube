import MioTubeCore
import SwiftUI

/// Glass controls over the video surface: scrubber with chapter ticks, transport, speed,
/// quality, captions, PiP, fullscreen. Auto-hides after 3 s of no touch while playing.
/// Swipe up enters fullscreen; swipe down leaves it, or minimizes the player when inline.
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
  private var isLoading: Bool {
    engine.isBuffering || coordinator.phase == .resolving || engine.status == .loading
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

        // With controls showing, the spinner lives inside the play button; only when they're
        // hidden does it appear on its own, so it never sits on top of a control.
        if isLoading && !controlsVisible {
          ProgressView()
            .controlSize(coordinator.isFullscreen ? .large : .regular)
            .tint(.white)
            .padding(10)
            .glassControl(interactive: false)
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
          ZStack {
            if isLoading {
              ProgressView()
                .controlSize(coordinator.isFullscreen ? .large : .regular)
                .tint(.white)
            } else {
              Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                .font(metrics.playFont)
                .contentTransition(.symbolEffect(.replace))
            }
          }
          .frame(width: metrics.play, height: metrics.play)
        }
        .glassControl()
        .accessibilityLabel(isLoading ? "Loading, pause" : (engine.isPlaying ? "Pause" : "Play"))

        transportButton("goforward.10", label: "Forward 10 seconds") { engine.skip(by: 10) }
        transportButton("forward.end.fill", label: "Next", enabled: coordinator.hasNext) { coordinator.advance(.user) }
      }
    }
  }

  private var scrubber: some View {
    let shown = scrubbing ? scrubValue : engine.position
    return VStack(spacing: coordinator.isFullscreen ? 6 : 2) {
      sponsorActions
      ScrubberBar(
        duration: engine.duration,
        position: shown,
        segments: coordinator.scrubberSegments,
        chapters: coordinator.info?.chapters ?? [],
        isScrubbing: scrubbing,
        isEnabled: coordinator.info?.isLive != true && engine.duration > 0,
        height: coordinator.isFullscreen ? 5 : 4,
        onScrub: { value in
          scrubValue = value
          scrubbing = true
          touch()
        },
        onCommit: { value in
          engine.seek(to: value, precise: true)
          scrubbing = false
          touch()
        }
      )
      HStack(spacing: 6) {
        Text(Format.duration(shown)).monospacedDigit()
        if scrubbing, let segment = coordinator.scrubberSegments.first(where: { $0.action != .poi && $0.start <= shown && shown < $0.end }) {
          SponsorLabel(category: segment.category)
        } else if coordinator.fullVideoSponsored {
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

  /// "Skip sponsor" for segments that are not auto-skipped (mute action or undone skip) and
  /// "Highlight" to jump to the video's point of interest.
  @ViewBuilder
  private var sponsorActions: some View {
    let skippable = coordinator.manuallySkippableSegment
    let highlight = coordinator.upcomingHighlight
    if skippable != nil || highlight != nil {
      HStack(spacing: 8) {
        Spacer()
        if let highlight {
          sponsorButton("Highlight", systemImage: "star.fill", category: highlight.category) { coordinator.skip(highlight) }
        }
        if let skippable {
          sponsorButton("Skip \(skippable.category.displayName.lowercased())", systemImage: "forward.fill", category: skippable.category) {
            coordinator.skip(skippable)
          }
        }
      }
      .transition(.opacity)
    }
  }

  private func sponsorButton(_ title: String, systemImage: String, category: SponsorCategory, action: @escaping () -> Void) -> some View {
    Button {
      action()
      touch()
    } label: {
      HStack(spacing: 5) {
        Circle().fill(category.color).frame(width: 7, height: 7)
        Label(title, systemImage: systemImage)
      }
      .font((coordinator.isFullscreen ? Font.footnote : Font.caption2).weight(.semibold))
      .padding(.horizontal, 10)
      .padding(.vertical, coordinator.isFullscreen ? 7 : 5)
    }
    .glassControl()
  }

  @ViewBuilder
  private var sponsorToast: some View {
    if let toast = coordinator.sponsorToast {
      Group {
        switch toast.kind {
        case .skipped:
          GlassToast(text: "Skipped \(toast.segment.category.displayName.lowercased())", systemImage: "forward.fill", accent: toast.segment.category.color) {
            Button("Undo") { coordinator.undoSkip() }
              .font(.subheadline.weight(.semibold))
          }
        case .muted:
          GlassToast(text: "Muted \(toast.segment.category.displayName.lowercased())", systemImage: "speaker.slash.fill", accent: toast.segment.category.color)
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

  /// Vertical swipe on the video: up enters fullscreen; down leaves fullscreen, or minimizes
  /// the player when inline. Short flicks count via the predicted end translation.
  private func swipe(_ value: DragGesture.Value) {
    let dy = value.translation.height
    let predicted = value.predictedEndTranslation.height
    guard abs(dy) > abs(value.translation.width) * 1.5, abs(dy) > 40 || abs(predicted) > 120 else { return }
    if dy < 0 {
      if !coordinator.isFullscreen { coordinator.isFullscreen = true }
    } else if coordinator.isFullscreen {
      coordinator.isFullscreen = false
    } else {
      dismiss()
    }
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

/// Custom scrubber so SponsorBlock segments, highlights and chapter gaps line up exactly with
/// the playhead (a system `Slider` insets its track by an unknown thumb margin).
struct ScrubberBar: View {
  let duration: Double
  let position: Double
  let segments: [SponsorSegment]
  let chapters: [Chapter]
  let isScrubbing: Bool
  let isEnabled: Bool
  let height: CGFloat
  let onScrub: (Double) -> Void
  let onCommit: (Double) -> Void

  var body: some View {
    GeometryReader { proxy in
      let width = max(proxy.size.width, 1)
      let bar = isScrubbing ? height * 1.8 : height
      let thumb: CGFloat = isScrubbing ? 16 : 12
      let x: (Double) -> CGFloat = { seconds in
        duration > 0 ? width * CGFloat(min(max(seconds / duration, 0), 1)) : 0
      }
      ZStack(alignment: .leading) {
        ZStack(alignment: .leading) {
          Rectangle().fill(.white.opacity(0.3))
          Rectangle().fill(Color.red).frame(width: x(position))
          ForEach(segments.filter { $0.action != .poi }, id: \.uuid) { segment in
            Rectangle()
              .fill(segment.category.color.opacity(0.9))
              .frame(width: max(2, x(segment.end) - x(segment.start)))
              .offset(x: x(segment.start))
          }
          ForEach(chapters.dropFirst(), id: \.startSeconds) { chapter in
            Rectangle()
              .fill(.black.opacity(0.7))
              .frame(width: 2)
              .offset(x: x(chapter.startSeconds) - 1)
          }
        }
        .frame(height: bar)
        .clipShape(.capsule)

        ForEach(segments.filter { $0.action == .poi }, id: \.uuid) { highlight in
          RoundedRectangle(cornerRadius: 1.5)
            .fill(highlight.category.color)
            .frame(width: 3, height: bar + 6)
            .offset(x: x(highlight.start) - 1.5)
        }

        Circle()
          .fill(.white)
          .frame(width: thumb, height: thumb)
          .shadow(color: .black.opacity(0.4), radius: 2)
          .offset(x: x(position) - thumb / 2)
          .opacity(isEnabled ? 1 : 0)
      }
      .frame(width: width, height: proxy.size.height)
      .contentShape(.rect)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { value in onScrub(seconds(at: value.location.x, width: width)) }
          .onEnded { value in onCommit(seconds(at: value.location.x, width: width)) }
      )
      .allowsHitTesting(isEnabled)
    }
    .frame(height: 24)
    .animation(.easeOut(duration: 0.15), value: isScrubbing)
    .accessibilityElement()
    .accessibilityLabel("Playback position")
    .accessibilityValue(Format.duration(position))
    .accessibilityAdjustableAction { direction in
      switch direction {
      case .increment: onCommit(min(position + 10, duration))
      case .decrement: onCommit(max(position - 10, 0))
      @unknown default: break
      }
    }
  }

  private func seconds(at x: CGFloat, width: CGFloat) -> Double {
    duration * Double(min(max(x / width, 0), 1))
  }
}

/// Coloured category tag (e.g. while scrubbing through a segment).
struct SponsorLabel: View {
  let category: SponsorCategory

  var body: some View {
    HStack(spacing: 4) {
      Circle().fill(category.color).frame(width: 6, height: 6)
      Text(category.displayName)
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(.black.opacity(0.45), in: .capsule)
  }
}
