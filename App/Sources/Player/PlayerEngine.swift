import AVFoundation
import AVKit
import MioTubeCore
import Observation
import UIKit

/// Owns the one `AVPlayer`, its KVO/notification plumbing and the audio session.
@Observable
final class PlayerEngine {
  nonisolated enum Status: Equatable {
    case idle
    case loading
    case ready
    case failed(String)
  }

  @ObservationIgnored let player = AVPlayer()
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

  init() {
    surface.engine = self
    surface.attach(player)
    player.automaticallyWaitsToMinimizeStalling = true
    player.allowsExternalPlayback = true
    surface.onPiPActiveChange = { [weak self] active in self?.isPiPActive = active }
    observePlayer()
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
    let item = AVPlayerItem(asset: AVURLAsset(url: url))
    item.audioTimePitchAlgorithm = .timeDomain
    qualityCap = quality
    applyQuality(to: item)
    observe(item)
    player.replaceCurrentItem(with: item)
    player.defaultRate = rate
    surface.setUpPictureInPicture(autoStart: pipAutoStart)
    if autoplay { activateAudioSession() }
  }

  func stop() {
    tearDownItem()
    player.replaceCurrentItem(with: nil)
    surface.tearDownPictureInPicture()
    status = .idle
    position = 0
    duration = 0
    isPlaying = false
  }

  private func tearDownItem() {
    itemObservations.forEach { $0.invalidate() }
    itemObservations = []
    itemNotificationTokens.forEach { NotificationCenter.default.removeObserver($0) }
    itemNotificationTokens = []
  }

  // MARK: Transport

  func play() {
    activateAudioSession()
    interruptedByCall = false
    player.playImmediately(atRate: rate)
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
    let clamped = max(0, duration > 0 ? min(seconds, duration - 0.25) : seconds)
    position = clamped
    let time = CMTime(seconds: clamped, preferredTimescale: 600)
    let tolerance: CMTime = precise ? .zero : .positiveInfinity
    player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { @Sendable [weak self] _ in
      Task { @MainActor in self?.onStateChange?() }
    }
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

  private func observePlayer() {
    playerObservations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] player, _ in
      let status = player.timeControlStatus
      Task { @MainActor in self?.apply(status) }
    })
    timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { @Sendable [weak self] time in
      let seconds = time.seconds
      MainActor.assumeIsolated { self?.tick(seconds) }
    }
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
    guard seconds.isFinite else { return }
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
      status = .ready
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
    error = message
    status = .failed(message)
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
