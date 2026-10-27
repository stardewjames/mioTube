import AVFoundation
import AVKit
import MioTubeCore
import Observation
import UIKit

/// Owns the active `AVPlayer`, its KVO/notification plumbing and the audio session. A second,
/// muted "standby" player can pre-buffer the landing point of an upcoming SponsorBlock skip;
/// the skip then swaps players instead of seeking.
@Observable
final class PlayerEngine {
  nonisolated enum Status: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
  }

  @ObservationIgnored private(set) var player = AVPlayer()
  @ObservationIgnored let surface = PlayerSurfaceView()

  private(set) var status: Status = .idle
  private(set) var duration: Double = 0
  private(set) var position: Double = 0
  private(set) var isPlaying = false
  private(set) var isBuffering = false
  private(set) var isPiPActive = false
  private(set) var isMuted = false
  private(set) var interruptedByCall = false
  private(set) var error: String?
  private(set) var lastErrorLog: String?
  /// User-selected speed; applied on every play.
  var rate: Float = 1 {
    didSet {
      player.defaultRate = rate
      if isPlaying { player.rate = rate }
      onStateChange?()
    }
  }

  @ObservationIgnored var onTick: ((Double) -> Void)?
  @ObservationIgnored var onEnd: (() -> Void)?
  /// Play/pause/seek/rate changes (Now Playing refresh).
  @ObservationIgnored var onStateChange: (() -> Void)?
  /// Pause triggered by the system (interruption, route loss) so progress can be saved.
  @ObservationIgnored var onSystemPause: (() -> Void)?
  /// The loaded stream failed (item error, fatal playback error, or never became ready).
  @ObservationIgnored var onFailure: ((String) -> Void)?

  @ObservationIgnored private var timeObserver: Any?
  @ObservationIgnored private var itemObservations: [NSKeyValueObservation] = []
  @ObservationIgnored private var playerObservations: [NSKeyValueObservation] = []
  @ObservationIgnored private var itemNotificationTokens: [any NSObjectProtocol] = []
  @ObservationIgnored private var sessionNotificationTokens: [any NSObjectProtocol] = []
  @ObservationIgnored private var pendingStart: Double = 0
  @ObservationIgnored private var pendingAutoplay = true
  @ObservationIgnored private var audioSessionActive = false
  @ObservationIgnored private var hosts = NSHashTable<PlayerHostView>.weakObjects()
  @ObservationIgnored private var qualityCap: QualityCap = .auto
  @ObservationIgnored private var seekGeneration = 0
  @ObservationIgnored private(set) var isSeeking = false
  @ObservationIgnored private var loadWatchdog: Task<Void, Never>?
  /// A stream that is not ready by then is treated as failed so another profile can be tried.
  static let loadTimeout: Duration = .seconds(15)

  /// Muted player parked at a skip's landing point.
  private struct Standby {
    let player: AVPlayer
    let item: AVPlayerItem
    let target: Double
    let observation: NSKeyValueObservation
    var seekIssued = false
    var isPositioned = false
  }

  @ObservationIgnored private var standby: Standby?
  @ObservationIgnored private var standbyID: UUID?
  @ObservationIgnored private var currentAsset: AVURLAsset?
  @ObservationIgnored private var forwardBufferLimit: Double?

  init() {
    surface.engine = self
    surface.attach(player)
    Self.configure(player)
    surface.onPiPActiveChange = { [weak self] active in self?.isPiPActive = active }
    bind(player)
    observeAudioSession()
  }

  // MARK: Surface hosts

  func register(_ host: PlayerHostView) { hosts.add(host) }

  func unregister(_ host: PlayerHostView) {
    hosts.remove(host)
    for other in hosts.allObjects where other.isActive { other.claimIfPossible() }
  }

  // MARK: Loading

  func load(_ source: PlaybackSource, startAt: Double, autoplay: Bool = true, quality: QualityCap, pipAutoStart: Bool) {
    tearDownItem()
    discardStandby()
    forwardBufferLimit = nil
    guard let url = source.url else {
      if case .unavailable(let failure) = source {
        status = .failed(failure.reasons.last?.reason ?? "Playback unavailable")
      }
      return
    }
    error = nil
    lastErrorLog = nil
    status = .loading
    position = startAt
    duration = 0
    pendingStart = startAt
    pendingAutoplay = autoplay
    let asset = AVURLAsset(url: url)
    currentAsset = asset
    let item = AVPlayerItem(asset: asset)
    item.audioTimePitchAlgorithm = .timeDomain
    qualityCap = quality
    applyQuality(to: item)
    observe(item)
    player.replaceCurrentItem(with: item)
    player.defaultRate = rate
    surface.setUpPictureInPicture(autoStart: pipAutoStart)
    if autoplay { activateAudioSession() }
    loadWatchdog = Task { [weak self] in
      try? await Task.sleep(for: Self.loadTimeout)
      guard !Task.isCancelled, let self, self.status == .loading else { return }
      self.fail("Stream did not start within 15 s")
    }
  }

  func stop() {
    tearDownItem()
    discardStandby()
    currentAsset = nil
    player.replaceCurrentItem(with: nil)
    surface.tearDownPictureInPicture()
    status = .idle
    position = 0
    duration = 0
    isPlaying = false
  }

  private func tearDownItem() {
    loadWatchdog?.cancel()
    loadWatchdog = nil
    // A new or cleared item invalidates any in-flight seek.
    seekGeneration += 1
    isSeeking = false
    itemObservations.forEach { $0.invalidate() }
    itemObservations = []
    itemNotificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    itemNotificationTokens = []
  }

  // MARK: Transport

  func play() {
    guard player.currentItem != nil else { return }
    activateAudioSession()
    interruptedByCall = false
    // `play()` (not `playImmediately`) lets AVPlayer wait for enough buffer; forcing playback
    // on an empty buffer after a jump made it repeat one frame instead of loading.
    player.defaultRate = rate
    player.play()
    onStateChange?()
  }

  func pause() {
    player.pause()
    onStateChange?()
  }

  func togglePlayPause() {
    isPlaying ? pause() : play()
  }

  func seek(to seconds: Double, precise: Bool = true) {
    let tolerance: CMTime = precise ? .zero : .positiveInfinity
    seek(to: seconds, toleranceBefore: tolerance, toleranceAfter: tolerance)
  }

  /// Jumps past a SponsorBlock segment: never lands before `seconds` (which would re-enter the
  /// segment) but may snap up to 1 s later to the next keyframe, so long skips are fast.
  func seekPast(_ seconds: Double) {
    seek(to: seconds, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600))
  }

  /// While a seek is in flight the periodic observer still reports the *old* time; those
  /// ticks are dropped so SponsorBlock doesn't re-trigger the same skip (a seek storm that
  /// stalls playback on long segments). Only the latest seek's completion ends the window.
  private func seek(to seconds: Double, toleranceBefore: CMTime, toleranceAfter: CMTime) {
    let clamped = max(0, duration > 0 ? min(seconds, duration - 0.25) : seconds)
    position = clamped
    seekGeneration += 1
    let generation = seekGeneration
    isSeeking = true
    let time = CMTime(seconds: clamped, preferredTimescale: 600)
    player.seek(to: time, toleranceBefore: toleranceBefore, toleranceAfter: toleranceAfter) { @Sendable [weak self] _ in
      Task { @MainActor in
        guard let self, generation == self.seekGeneration else { return }
        self.isSeeking = false
        self.onStateChange?()
      }
    }
  }

  // MARK: SponsorBlock buffering

  /// Caps how far ahead the active item buffers so it doesn't download a segment that is
  /// about to be skipped. `nil` restores automatic buffering. Applied in whole seconds to
  /// avoid re-setting the item on every tick.
  func limitForwardBuffer(_ seconds: Double?) {
    let rounded = seconds.map { max(2, $0.rounded(.up)) }
    guard rounded != forwardBufferLimit else { return }
    forwardBufferLimit = rounded
    player.currentItem?.preferredForwardBufferDuration = rounded ?? 0
  }

  /// Starts buffering `target` (a skip's landing point) in a muted standby player.
  func prepareStandby(at target: Double) {
    guard let asset = currentAsset, status == .ready, canSwapPlayers else { return }
    if let standby, abs(standby.target - target) < 0.5 { return }
    discardStandby()
    let item = AVPlayerItem(asset: asset)
    item.audioTimePitchAlgorithm = .timeDomain
    item.preferredForwardBufferDuration = 8
    applyQuality(to: item)
    let standbyPlayer = AVPlayer(playerItem: item)
    Self.configure(standbyPlayer)
    standbyPlayer.isMuted = true
    let id = UUID()
    let observation = item.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
      guard item.status == .readyToPlay else { return }
      Task { @MainActor in self?.positionStandby(id) }
    }
    standby = Standby(player: standbyPlayer, item: item, target: target, observation: observation)
    standbyID = id
  }

  /// Skip over a segment ending at `target`: swap to the pre-buffered standby player when it
  /// is parked there, otherwise seek.
  func jumpOverSegment(to target: Double) {
    limitForwardBuffer(nil)
    guard let ready = standby, ready.isPositioned, abs(ready.target - target) < 1, canSwapPlayers,
          Self.hasBuffer(ready.item, at: ready.target) else {
      discardStandby()
      seekPast(target)
      return
    }
    ready.observation.invalidate()
    standby = nil
    standbyID = nil
    swap(to: ready.player, item: ready.item)
  }

  /// Swapping the layer's player while in PiP or AirPlay would interrupt them; seek instead.
  private var canSwapPlayers: Bool { !isPiPActive && !player.isExternalPlaybackActive }

  private func positionStandby(_ id: UUID) {
    guard standbyID == id, var parked = standby, !parked.seekIssued else { return }
    parked.seekIssued = true
    standby = parked
    let time = CMTime(seconds: parked.target, preferredTimescale: 600)
    parked.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: CMTime(seconds: 1, preferredTimescale: 600)) { @Sendable [weak self] finished in
      Task { @MainActor in
        guard finished, let self, self.standbyID == id else { return }
        self.standby?.isPositioned = true
      }
    }
  }

  private func discardStandby() {
    guard let parked = standby else { return }
    parked.observation.invalidate()
    parked.player.pause()
    parked.player.replaceCurrentItem(with: nil)
    standby = nil
    standbyID = nil
  }

  private func swap(to newPlayer: AVPlayer, item: AVPlayerItem) {
    let old = player
    let wasPlaying = isPlaying
    unbind(old)
    tearDownItem()
    old.pause()
    item.preferredForwardBufferDuration = 0
    newPlayer.isMuted = isMuted
    newPlayer.defaultRate = rate
    player = newPlayer
    forwardBufferLimit = nil
    bind(newPlayer)
    observe(item)
    // Keep the background "detached" state if the layer is currently detached.
    if surface.playerLayer.player != nil { surface.attach(newPlayer) }
    let landed = item.currentTime().seconds
    if landed.isFinite { position = landed }
    if wasPlaying { newPlayer.play() }
    old.replaceCurrentItem(with: nil)
    onStateChange?()
  }

  func skip(by delta: Double) {
    seek(to: position + delta, precise: false)
  }

  func setMuted(_ muted: Bool) {
    player.isMuted = muted
    isMuted = muted
  }

  func setQuality(_ cap: QualityCap) {
    qualityCap = cap
    if let item = player.currentItem { applyQuality(to: item) }
  }

  private func applyQuality(to item: AVPlayerItem) {
    if let height = qualityCap.maxHeight {
      item.preferredMaximumResolution = CGSize(width: 1920, height: height)
    } else {
      item.preferredMaximumResolution = .zero
    }
    item.preferredPeakBitRate = qualityCap.peakBitRate ?? 0
  }

  var isPictureInPicturePossible: Bool { surface.isPictureInPicturePossible }

  func togglePictureInPicture() { surface.togglePictureInPicture() }

  func stopPictureInPicture() { surface.pipController?.stopPictureInPicture() }

  // MARK: Background

  func didEnterBackground(keepPlaying: Bool) {
    guard !isPiPActive else { return }
    if keepPlaying {
      // A visible-less AVPlayerLayer would make AVFoundation pause video; audio continues detached.
      surface.detachForBackground()
    } else {
      pause()
    }
  }

  func willEnterForeground() {
    if surface.playerLayer.player == nil { surface.attach(player) }
  }

  // MARK: Observation

  private static func configure(_ player: AVPlayer) {
    player.automaticallyWaitsToMinimizeStalling = true
    player.allowsExternalPlayback = true
    // Captions are drawn by CaptionOverlay; AVPlayer must not also render a legible track.
    player.appliesMediaSelectionCriteriaAutomatically = false
  }

  /// The standby is only worth swapping to once it actually holds media past the target.
  private static func hasBuffer(_ item: AVPlayerItem, at seconds: Double) -> Bool {
    if item.isPlaybackLikelyToKeepUp { return true }
    return item.loadedTimeRanges.contains { value in
      let range = value.timeRangeValue
      return range.start.seconds <= seconds + 1 && range.end.seconds >= seconds + 3
    }
  }

  /// Turns off any subtitle/CC rendition the stream carries.
  private func disableNativeSubtitles(_ item: AVPlayerItem) {
    let asset = item.asset
    Task {
      guard let group = try? await asset.loadMediaSelectionGroup(for: .legible) else { return }
      item.select(nil, in: group)
    }
  }

  private func bind(_ player: AVPlayer) {
    playerObservations = [player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] player, _ in
      let status = player.timeControlStatus
      Task { @MainActor in self?.apply(status) }
    }]
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { @Sendable [weak self] time in
      let seconds = time.seconds
      MainActor.assumeIsolated { self?.tick(seconds) }
    }
  }

  private func unbind(_ player: AVPlayer) {
    playerObservations.forEach { $0.invalidate() }
    playerObservations = []
    if let timeObserver { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
  }

  private func apply(_ status: AVPlayer.TimeControlStatus) {
    let playing = status != .paused
    isBuffering = status == .waitingToPlayAtSpecifiedRate
    if playing != isPlaying {
      isPlaying = playing
      onStateChange?()
    }
  }

  private func tick(_ seconds: Double) {
    guard seconds.isFinite, !isSeeking else { return }
    position = seconds
    if let item = player.currentItem {
      let total = item.duration.seconds
      if total.isFinite, total > 0, total != duration { duration = total }
    }
    onTick?(seconds)
  }

  private func observe(_ item: AVPlayerItem) {
    itemObservations.append(item.observe(\.status, options: [.new]) { @Sendable [weak self] item, _ in
      let status = item.status
      let message = item.error?.localizedDescription
      Task { @MainActor in self?.itemStatusChanged(status, message: message) }
    })
    let center = NotificationCenter.default
    itemNotificationTokens.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { @Sendable [weak self] _ in
      MainActor.assumeIsolated { self?.onEnd?() }
    })
    itemNotificationTokens.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { @Sendable [weak self] note in
      let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)?.localizedDescription
      MainActor.assumeIsolated { self?.fail(message ?? "Playback stopped unexpectedly") }
    })
    itemNotificationTokens.append(center.addObserver(forName: AVPlayerItem.newErrorLogEntryNotification, object: item, queue: .main) { @Sendable [weak self] note in
      let event = (note.object as? AVPlayerItem)?.errorLog()?.events.last
      let message = event.map { "\($0.errorStatusCode) \($0.errorComment ?? "")" }
      MainActor.assumeIsolated { self?.lastErrorLog = message }
    })
  }

  private func itemStatusChanged(_ itemStatus: AVPlayerItem.Status, message: String?) {
    switch itemStatus {
    case .readyToPlay:
      guard status == .loading else { return }
      loadWatchdog?.cancel()
      status = .ready
      if let item = player.currentItem { disableNativeSubtitles(item) }
      if pendingStart > 0 {
        seek(to: pendingStart)
        pendingStart = 0
      }
      if pendingAutoplay { play() }
    case .failed:
      fail(message ?? "The video could not be played")
    default:
      break
    }
  }

  private func fail(_ message: String) {
    guard status != .idle else { return }
    loadWatchdog?.cancel()
    error = message
    status = .failed(message)
    onFailure?(message)
  }

  // MARK: Audio session

  func activateAudioSession() {
    guard !audioSessionActive else { return }
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
      audioSessionActive = true
    } catch {
      lastErrorLog = "Audio session: \(error.localizedDescription)"
    }
  }

  private func observeAudioSession() {
    let center = NotificationCenter.default
    sessionNotificationTokens.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { @Sendable [weak self] note in
      let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
      let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
      MainActor.assumeIsolated { self?.handleInterruption(type, options: options) }
    })
    sessionNotificationTokens.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { @Sendable [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
      MainActor.assumeIsolated {
        if reason == .oldDeviceUnavailable {
          self?.pause()
          self?.onSystemPause?()
        }
      }
    })
  }

  private func handleInterruption(_ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
    switch type {
    case .began:
      if isPlaying {
        interruptedByCall = true
        pause()
        onSystemPause?()
      }
    case .ended:
      audioSessionActive = false
      if interruptedByCall && options.contains(.shouldResume) { play() }
      interruptedByCall = false
    default:
      break
    }
  }
}
