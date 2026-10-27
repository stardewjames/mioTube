import MediaPlayer
import UIKit

/// Lock screen / Control Center metadata and remote commands.
final class NowPlayingCenter {
  struct Handlers {
    var play: () -> Bool
    var pause: () -> Bool
    var toggle: () -> Bool
    var next: () -> Bool
    var previous: () -> Bool
    var seek: (Double) -> Bool
    var skip: (Double) -> Bool
  }

  private var artworkURL: URL?
  private var artwork: MPMediaItemArtwork?
  private var activated = false

  /// Registers remote-command targets once at launch. Each handler reports `.success` only
  /// after the change was applied.
  func activate(_ handlers: Handlers) {
    guard !activated else { return }
    activated = true
    let center = MPRemoteCommandCenter.shared()
    func status(_ ok: Bool) -> MPRemoteCommandHandlerStatus { ok ? .success : .commandFailed }
    center.playCommand.addTarget { _ in status(handlers.play()) }
    center.pauseCommand.addTarget { _ in status(handlers.pause()) }
    center.togglePlayPauseCommand.addTarget { _ in status(handlers.toggle()) }
    center.nextTrackCommand.addTarget { _ in status(handlers.next()) }
    center.previousTrackCommand.addTarget { _ in status(handlers.previous()) }
    center.changePlaybackPositionCommand.addTarget { event in
      guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
      return status(handlers.seek(event.positionTime))
    }
    center.skipForwardCommand.preferredIntervals = [15]
    center.skipBackwardCommand.preferredIntervals = [15]
    center.skipForwardCommand.addTarget { _ in status(handlers.skip(15)) }
    center.skipBackwardCommand.addTarget { _ in status(handlers.skip(-15)) }
  }

  func update(title: String, artist: String, duration: Double, elapsed: Double, rate: Float, isLive: Bool) {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: artist,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
      MPNowPlayingInfoPropertyPlaybackRate: rate,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
      MPNowPlayingInfoPropertyIsLiveStream: isLive,
      MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
    ]
    if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
    if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    MPRemoteCommandCenter.shared().changePlaybackPositionCommand.isEnabled = !isLive
  }

  /// Sets artwork for `url` (decoded thumbnail) and refreshes the info dictionary.
  func setArtwork(_ image: UIImage?, for url: URL?) {
    guard url != artworkURL || artwork == nil else { return }
    artworkURL = url
    artwork = image.map(Self.makeArtwork)
    if var info = MPNowPlayingInfoCenter.default().nowPlayingInfo {
      info[MPMediaItemPropertyArtwork] = artwork
      MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
  }

  func clear() {
    artworkURL = nil
    artwork = nil
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  /// The request handler runs on an arbitrary queue; it must not be main-actor isolated.
  nonisolated private static func makeArtwork(_ image: UIImage) -> MPMediaItemArtwork {
    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
  }
}
