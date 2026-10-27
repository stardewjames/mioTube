import AVFoundation
import MioTubeCore
import Observation
import SwiftUI
import UIKit

nonisolated struct QueueItem: Identifiable, Hashable {
  let id = UUID()
  let video: VideoSummary
}

nonisolated enum RepeatMode: String, CaseIterable {
  case off, one, all
}

nonisolated enum AdvanceReason {
  case automatic, user
}

nonisolated struct SponsorToast: Equatable, Identifiable {
  enum Kind: Equatable {
    case skipped(from: Double)
    case muted
  }

  let id = UUID()
  let segment: SponsorSegment
  let kind: Kind
}

/// Single owner of queue, SponsorBlock, audio session, PiP state and rotation.
@Observable
final class PlaybackCoordinator {
  nonisolated enum Phase: Equatable {
    case idle
    case resolving
    case playing
    case failed(PlaybackFailure)
  }

  static var shared: PlaybackCoordinator { AppEnvironment.shared.coordinator }

  let engine = PlayerEngine()

  private(set) var queue: [QueueItem] = []
  private(set) var index = 0
  var repeatMode: RepeatMode = .off
  private(set) var phase: Phase = .idle
  private(set) var info: WatchInfo?
  var isWatchPresented = false
  static let miniPlayerZoomID = "mini-player"
  /// `matchedTransitionSource` id the watch screen zooms from/to: the tapped card when opening
  /// from a feed, then the mini-player, so minimizing shrinks the player into the mini-player.
  var watchZoomSource: String = PlaybackCoordinator.miniPlayerZoomID
  var isFullscreen = false {
    didSet { if oldValue != isFullscreen { applyOrientation() } }
  }
  /// Drives the "playback unavailable" sheet.
  var failure: PlaybackFailure?
  private(set) var lastResolution: Resolution?

  // SponsorBlock
  private(set) var sponsorSegments: [SponsorSegment] = []
  private(set) var fullVideoSponsored = false
  var sponsorToast: SponsorToast?

  // Captions
  private(set) var captionTracks: [CaptionTrack] = []
  private(set) var selectedCaption: CaptionTrack?
  private(set) var currentCaption: String?
  private(set) var isLoadingCaptions = false

  private(set) var quality: QualityCap = .auto

  @ObservationIgnored private let resolver: StreamResolver
  @ObservationIgnored private let client: InnertubeClient
  @ObservationIgnored private let sponsorBlock: SponsorBlockClient
  @ObservationIgnored private let transport: any HTTPTransport
  @ObservationIgnored private let settings: Settings
  @ObservationIgnored private let progress: WatchProgressStore
  @ObservationIgnored private let images: ImagePipeline
  @ObservationIgnored private let nowPlaying = NowPlayingCenter()
  @ObservationIgnored private var loadTask: Task<Void, Never>?
  @ObservationIgnored private var toastTask: Task<Void, Never>?
  @ObservationIgnored private var skipEngine: SkipEngine?
  @ObservationIgnored private var skipConfig: SkipConfig?
  @ObservationIgnored private var suppressedSegments: [SponsorSegment] = []
  @ObservationIgnored private var captions: Captions?
  @ObservationIgnored private var pendingPiPRestore: ((Bool) -> Void)?
  /// Profiles whose stream failed in AVPlayer for the current video, with the reasons.
  @ObservationIgnored private var failedProfiles: Set<String> = []
  @ObservationIgnored private var playerFailureReasons: [PlaybackFailure.Reason] = []
  @ObservationIgnored private var fallbackTask: Task<Void, Never>?
  @ObservationIgnored private var restoreFromPiPWhenActive = false
  @ObservationIgnored private var lastProgressSave: Date = .distantPast
  @ObservationIgnored private var lifecycleTokens: [any NSObjectProtocol] = []

  nonisolated private struct SkipConfig: Equatable {
    var enabled: Set<SponsorCategory>
    var overrides: [SponsorCategory: SponsorAction]
    var forced: Bool
  }

  init(
    resolver: StreamResolver, client: InnertubeClient, sponsorBlock: SponsorBlockClient, transport: any HTTPTransport,
    settings: Settings, progress: WatchProgressStore, images: ImagePipeline
  ) {
    self.resolver = resolver
    self.client = client
    self.sponsorBlock = sponsorBlock
    self.transport = transport
    self.settings = settings
    self.progress = progress
    self.images = images
    quality = settings.defaultQuality
    engine.rate = Float(settings.defaultSpeed)
    engine.onTick = { [weak self] position in self?.tick(position) }
    engine.onEnd = { [weak self] in self?.advance(.automatic) }
    engine.onStateChange = { [weak self] in self?.refreshNowPlaying() }
    engine.onSystemPause = { [weak self] in self?.saveProgress(force: true) }
    engine.onFailure = { [weak self] message in self?.streamFailed(message) }
    engine.surface.onRestoreUserInterface = { [weak self] completion in
      guard let self else { return completion(true) }
      if isWatchPresented {
        completion(true)
      } else {
        pendingPiPRestore = completion
        isWatchPresented = true
      }
    }
    observeLifecycle()
  }

  var current: QueueItem? { queue.indices.contains(index) ? queue[index] : nil }
  var hasNext: Bool { index + 1 < queue.count || (settings.autoplay && nextRelated != nil) }
  var hasPrevious: Bool { index > 0 }

  // MARK: Commands

  func play(_ video: VideoSummary, queue items: [VideoSummary]? = nil, present: Bool = true) {
    var list = items ?? [video]
    if !list.contains(where: { $0.videoID == video.videoID }) { list.insert(video, at: 0) }
    queue = list.map(QueueItem.init(video:))
    index = list.firstIndex { $0.videoID == video.videoID } ?? 0
    if present {
      if !isWatchPresented { watchZoomSource = video.videoID }
      isWatchPresented = true
    }
    startCurrent()
  }

  /// Called by the watch screen once visible, finishing a PiP "restore" request.
  func watchScreenDidAppear() {
    pendingPiPRestore?(true)
    pendingPiPRestore = nil
  }

  func playNext(_ video: VideoSummary) {
    guard !queue.isEmpty else {
      play(video, present: false)
      return
    }
    queue.insert(QueueItem(video: video), at: index + 1)
  }

  func advance(_ reason: AdvanceReason) {
    if reason == .automatic, repeatMode == .one {
      engine.seek(to: 0)
      engine.play()
      return
    }
    saveProgress(force: true)
    if index + 1 < queue.count {
      index += 1
    } else if repeatMode == .all, !queue.isEmpty {
      index = 0
    } else if settings.autoplay, let next = nextRelated {
      queue.append(QueueItem(video: next))
      index = queue.count - 1
    } else {
      if reason == .automatic { engine.pause() }
      return
    }
    startCurrent()
  }

  func previous() {
    if engine.position > 5 || index == 0 {
      engine.seek(to: 0)
      return
    }
    saveProgress(force: true)
    index -= 1
    startCurrent()
  }

  func jump(to item: QueueItem) {
    guard let target = queue.firstIndex(of: item), target != index else { return }
    saveProgress(force: true)
    index = target
    startCurrent()
  }

  func close() {
    saveProgress(force: true)
    loadTask?.cancel()
    engine.stop()
    nowPlaying.clear()
    queue = []
    index = 0
    info = nil
    phase = .idle
    isFullscreen = false
    isWatchPresented = false
    resetPerVideoState()
  }

  func retry() {
    failure = nil
    if let id = current?.video.videoID { Task { await resolver.invalidate(videoID: id) } }
    startCurrent()
  }

  func toggleMute() {
    engine.setMuted(!engine.isMuted)
    skipEngine?.userToggledMute()
  }

  func setQuality(_ cap: QualityCap) {
    quality = cap
    engine.setQuality(cap)
  }

  func setSpeed(_ speed: Double) {
    engine.rate = Float(speed)
  }

  func undoSkip() {
    guard let toast = sponsorToast, case .skipped(let from) = toast.kind else { return }
    suppressedSegments.append(toast.segment)
    skipEngine?.suppress(toast.segment)
    engine.seek(to: from)
    sponsorToast = nil
  }

  func selectCaption(_ track: CaptionTrack?) {
    selectedCaption = track
    captions = nil
    currentCaption = nil
    guard let track else { return }
    settings.preferredCaptionLanguage = track.languageCode
    isLoadingCaptions = true
    let transport = transport
    Task {
      let loaded = await CaptionsParser.fetch(track, transport: transport)
      guard selectedCaption == track else { return }
      isLoadingCaptions = false
      if let loaded {
        captions = loaded
        currentCaption = loaded.cue(at: engine.position)?.text
      } else {
        // Unavailable (403/empty): hide the entry rather than retrying.
        captionTracks.removeAll { $0 == track }
        selectedCaption = nil
      }
    }
  }

  var currentChapter: Chapter? {
    guard let chapters = info?.chapters, !chapters.isEmpty else { return nil }
    return chapters.last { $0.startSeconds <= engine.position }
  }

  // MARK: SponsorBlock on the scrubber

  /// Segments drawn on the scrubber: skip/mute ranges and highlights in enabled categories
  /// (plus the Diagnostics test segment).
  var scrubberSegments: [SponsorSegment] {
    var segments = sponsorSegments
    if settings.forceTestSponsorSegment { segments.append(Self.testSegment) }
    let enabled = settings.activeSponsorCategories
    return segments.filter { segment in
      guard enabled.contains(segment.category) || segment == Self.testSegment else { return false }
      return [.skip, .mute, .poi].contains(segment.action)
    }
  }

  /// Segment under the playhead that is *not* auto-skipped (mute action, or skip undone this
  /// session), offered as a manual "Skip" button.
  var manuallySkippableSegment: SponsorSegment? {
    let position = engine.position
    let suppressed = Set(suppressedSegments.map(\.uuid))
    return scrubberSegments.first { segment in
      guard segment.action != .poi, segment.start <= position, position < segment.end - 1 else { return false }
      let action = settings.sponsorCategoryActions[segment.category] ?? segment.action
      return action == .mute || suppressed.contains(segment.uuid)
    }
  }

  /// The video's highlight, while the playhead is still before it.
  var upcomingHighlight: SponsorSegment? {
    scrubberSegments.first { $0.action == .poi && engine.position < $0.start - 2 }
  }

  func skip(_ segment: SponsorSegment) {
    if segment.action == .poi { engine.seek(to: segment.start) } else { engine.jumpOverSegment(to: segment.end) }
  }

  // MARK: Loading

  private var nextRelated: VideoSummary? {
    let played = Set(queue.map(\.video.videoID))
    return info?.related.first { !played.contains($0.videoID) && !$0.isLive }
  }

  private func resetPerVideoState() {
    sponsorSegments = []
    fullVideoSponsored = false
    sponsorToast = nil
    skipEngine = nil
    skipConfig = nil
    suppressedSegments = []
    captionTracks = []
    selectedCaption = nil
    captions = nil
    currentCaption = nil
    failure = nil
    fallbackTask?.cancel()
    failedProfiles = []
    playerFailureReasons = []
  }

  /// A resolved stream would not play (e.g. it needs a JS transform or PO token): re-resolve
  /// with that profile excluded and resume at the same position.
  private func streamFailed(_ message: String) {
    guard phase == .playing, let item = current, let profile = lastResolution?.profileID else { return }
    failedProfiles.insert(profile)
    playerFailureReasons.append(.init(profile: profile, reason: "player: \(message)"))
    phase = .resolving
    let position = engine.position
    let excluded = failedProfiles
    let videoID = item.video.videoID
    let maxHeight = quality.maxHeight
    let resolver = resolver
    fallbackTask?.cancel()
    fallbackTask = Task {
      let resolution = await withTimeout(seconds: 30) {
        await resolver.resolveDetailed(videoID: videoID, maxHeight: maxHeight, excluding: excluded)
      }
      guard !Task.isCancelled, current?.id == item.id else { return }
      guard let resolution, resolution.source.url != nil else {
        var reasons = playerFailureReasons
        if case .unavailable(let failure)? = resolution?.source {
          reasons += failure.reasons.filter { !excluded.contains($0.profile) }
        }
        fail(PlaybackFailure(reasons: reasons))
        return
      }
      lastResolution = resolution
      engine.load(resolution.source, startAt: position, quality: quality, pipAutoStart: settings.pipAutoStart)
      phase = .playing
    }
  }

  private func startCurrent() {
    loadTask?.cancel()
    guard let item = current else { return }
    resetPerVideoState()
    engine.pause()
    info = WatchInfo(summary: item.video)
    phase = .resolving
    refreshNowPlaying()
    loadArtwork(for: item.video)
    let videoID = item.video.videoID
    let maxHeight = quality.maxHeight
    let resolver = resolver
    let client = client

    loadTask = Task {
      // `next` and SponsorBlock don't depend on the stream; fetch them alongside resolution so
      // the info panel fills in even when playback fails.
      async let nextJSON = try? client.post("next", ["videoId": .string(videoID)])
      async let segments = loadSegments(videoID: videoID)
      let resolution = await withTimeout(seconds: 30) {
        await resolver.resolveDetailed(videoID: videoID, maxHeight: maxHeight)
      }
      guard !Task.isCancelled, current?.id == item.id else { return }
      if let resolution {
        lastResolution = resolution
        if case .unavailable(let failure) = resolution.source {
          fail(failure)
        } else {
          let resume = await progress.resumePosition(for: videoID)
          guard !Task.isCancelled, current?.id == item.id else { return }
          engine.load(resolution.source, startAt: resume, quality: quality, pipAutoStart: settings.pipAutoStart)
          phase = .playing
        }
      } else {
        fail(PlaybackFailure(reasons: [.init(profile: "all", reason: "Timed out after 30 s")]))
      }

      let (next, loadedSegments) = await (nextJSON, segments)
      guard !Task.isCancelled, current?.id == item.id else { return }
      if let next {
        let loadedInfo = WatchParser.parse(next: next, player: resolution?.player ?? .null, adFilter: .init())
        info = loadedInfo
        captionTracks = loadedInfo.captionTracks
        AppEnvironment.shared.diagnostics.record(watchDroppedAds: loadedInfo.droppedAds)
        if let preferred = settings.preferredCaptionLanguage, selectedCaption == nil,
           let track = loadedInfo.captionTracks.first(where: { $0.languageCode == preferred && !$0.isAutomatic }) {
          selectCaption(track)
        }
      }
      sponsorSegments = loadedSegments
      rebuildSkipEngineIfNeeded(force: true)
      refreshNowPlaying()
    }
  }

  private func fail(_ failure: PlaybackFailure) {
    phase = .failed(failure)
    self.failure = failure
  }

  private func loadSegments(videoID: String) async -> [SponsorSegment] {
    var segments: [SponsorSegment] = []
    if settings.sponsorBlockEnabled {
      segments = (try? await sponsorBlock.segments(
        videoID: videoID, categories: SponsorCategory.allCases, server: settings.sponsorServerURL,
        privacyMode: settings.sponsorBlockPrivacyMode
      )) ?? []
    }
    return segments
  }

  private func loadArtwork(for video: VideoSummary) {
    guard let url = video.bestThumbnailURL else { return }
    let images = images
    Task {
      let image = await images.image(for: url, target: CGSize(width: 512, height: 288), scale: 1)
      guard current?.video.videoID == video.videoID else { return }
      nowPlaying.setArtwork(image, for: url)
    }
  }

  // MARK: SponsorBlock

  static let testSegment = SponsorSegment(uuid: "miotube-test-segment", start: 10, end: 15, category: .sponsor, action: .skip, votes: 0)

  private func rebuildSkipEngineIfNeeded(force: Bool = false) {
    let config = SkipConfig(
      enabled: settings.activeSponsorCategories,
      overrides: settings.sponsorCategoryActions,
      forced: settings.forceTestSponsorSegment
    )
    guard force || config != skipConfig else { return }
    skipConfig = config
    var segments = sponsorSegments
    var enabled = config.enabled
    if config.forced {
      segments.append(Self.testSegment)
      enabled.insert(Self.testSegment.category)
    }
    var engine = SkipEngine(segments: segments, enabled: enabled, categoryOverrides: config.overrides)
    for segment in suppressedSegments { engine.suppress(segment) }
    skipEngine = engine
    fullVideoSponsored = engine.fullVideoSponsored
  }

  private func tick(_ position: Double) {
    if skipEngine != nil || settings.forceTestSponsorSegment { rebuildSkipEngineIfNeeded() }
    if var engineState = skipEngine, phase == .playing {
      let decision = engineState.evaluate(position: position, muted: engine.isMuted)
      skipEngine = engineState
      switch decision {
      case .skip(let target, let segment):
        engine.jumpOverSegment(to: target)
        show(SponsorToast(segment: segment, kind: .skipped(from: position)))
      case .mute(let muted, let segment):
        engine.setMuted(muted)
        if muted, let segment {
          show(SponsorToast(segment: segment, kind: .muted))
        } else if case .muted = sponsorToast?.kind {
          sponsorToast = nil
        }
      case .none:
        break
      }
      if case .skip = decision {} else { prepareForUpcomingSkip(at: position, using: engineState) }
    } else {
      engine.limitForwardBuffer(nil)
    }
    if let captions {
      let text = captions.cue(at: position)?.text
      if text != currentCaption { currentCaption = text }
    }
    saveProgress(force: false)
  }

  /// Within 30 s of an auto-skip, cap forward buffering at the segment start so the skipped
  /// part isn't downloaded; within 20 s of a segment of 6 s or more, start pre-buffering its
  /// landing point in the standby player so the skip resumes instantly.
  private func prepareForUpcomingSkip(at position: Double, using skips: SkipEngine) {
    guard let upcoming = skips.upcomingSkip(after: position) else {
      engine.limitForwardBuffer(nil)
      return
    }
    let lead = upcoming.segment.start - position
    engine.limitForwardBuffer(lead < 30 ? lead + 1 : nil)
    let landsBeforeEnd = engine.duration <= 0 || upcoming.target < engine.duration - 2
    if lead < 20, upcoming.target - upcoming.segment.start >= 6, landsBeforeEnd {
      engine.prepareStandby(at: upcoming.target)
    }
  }

  private func show(_ toast: SponsorToast) {
    sponsorToast = toast
    toastTask?.cancel()
    guard case .skipped = toast.kind else { return }
    toastTask = Task {
      try? await Task.sleep(for: .seconds(5))
      if !Task.isCancelled, sponsorToast?.id == toast.id { sponsorToast = nil }
    }
  }

  // MARK: Progress

  private func saveProgress(force: Bool) {
    guard let id = current?.video.videoID, engine.duration > 0, info?.isLive != true else { return }
    let now = Date()
    guard force || now.timeIntervalSince(lastProgressSave) >= 5 else { return }
    lastProgressSave = now
    let position = engine.position
    let duration = engine.duration
    let progress = progress
    Task {
      await progress.record(videoID: id, position: position, duration: duration)
      await progress.flush()
    }
  }

  // MARK: Now Playing & remote commands

  func activateRemoteCommands() {
    nowPlaying.activate(NowPlayingCenter.Handlers(
      play: { [weak self] in
        guard let self, current != nil else { return false }
        engine.play()
        return true
      },
      pause: { [weak self] in
        guard let self, current != nil else { return false }
        engine.pause()
        saveProgress(force: true)
        return true
      },
      toggle: { [weak self] in
        guard let self, current != nil else { return false }
        engine.togglePlayPause()
        return true
      },
      next: { [weak self] in
        guard let self, hasNext else { return false }
        advance(.user)
        return true
      },
      previous: { [weak self] in
        guard let self, current != nil else { return false }
        previous()
        return true
      },
      seek: { [weak self] seconds in
        guard let self, current != nil else { return false }
        engine.seek(to: seconds)
        return true
      },
      skip: { [weak self] delta in
        guard let self, current != nil else { return false }
        engine.skip(by: delta)
        return true
      }
    ))
  }

  private func refreshNowPlaying() {
    guard let item = current else { return }
    nowPlaying.update(
      title: info?.title.isEmpty == false ? info!.title : item.video.title,
      artist: info?.channel?.title ?? item.video.channelName,
      duration: engine.duration,
      elapsed: engine.position,
      rate: engine.isPlaying ? engine.rate : 0,
      isLive: info?.isLive ?? item.video.isLive
    )
  }

  // MARK: Lifecycle & rotation

  private func observeLifecycle() {
    let center = NotificationCenter.default
    lifecycleTokens.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.current != nil else { return }
        self.saveProgress(force: true)
        self.engine.didEnterBackground(keepPlaying: self.settings.backgroundPlayback)
      }
    })
    lifecycleTokens.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.engine.willEnterForeground()
        // Only returns from the background count; in-app PiP (Control Center etc.) is left alone.
        self.restoreFromPiPWhenActive = self.engine.isPiPActive
      }
    })
    lifecycleTokens.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { @Sendable [weak self] _ in
      MainActor.assumeIsolated {
        guard let self, self.restoreFromPiPWhenActive else { return }
        self.restoreFromPiPWhenActive = false
        self.restoreFromPictureInPicture()
      }
    })
  }

  /// Returning to the app while PiP runs: bring the watch screen back in fullscreen, then stop
  /// PiP so the window animates into the visible player layer.
  private func restoreFromPictureInPicture() {
    guard current != nil, engine.isPiPActive else { return }
    isWatchPresented = true
    isFullscreen = true
    Task {
      try? await Task.sleep(for: .milliseconds(350))
      engine.stopPictureInPicture()
    }
  }

  private func applyOrientation() {
    guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
    var controller = scene.keyWindow?.rootViewController
    while let current = controller {
      current.setNeedsUpdateOfSupportedInterfaceOrientations()
      controller = current.presentedViewController
    }
    scene.requestGeometryUpdate(.iOS(interfaceOrientations: isFullscreen ? .landscapeRight : .portrait)) { _ in }
  }
}

/// Runs `operation`, returning nil if it does not finish within `seconds`.
func withTimeout<T: Sendable>(seconds: Double, _ operation: @escaping @Sendable () async -> T) async -> T? {
  await withTaskGroup(of: T?.self) { group in
    group.addTask { await operation() }
    group.addTask {
      try? await Task.sleep(for: .seconds(seconds))
      return nil
    }
    let first = await group.next() ?? nil
    group.cancelAll()
    return first
  }
}
