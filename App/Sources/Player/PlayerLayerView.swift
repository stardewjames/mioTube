import AVFoundation
import AVKit
import SwiftUI
import UIKit

/// The single `AVPlayerLayer` of the app. It is re-parented between the watch screen and the
/// mini-player so it is always in the view hierarchy while something plays (PiP eligibility)
/// and the PiP controller survives sheet dismissal.
final class PlayerSurfaceView: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  weak var engine: PlayerEngine?

  private(set) var pipController: AVPictureInPictureController?
  private let pipDelegate = PiPDelegate()

  var onPiPActiveChange: ((Bool) -> Void)? {
    get { pipDelegate.onActiveChange }
    set { pipDelegate.onActiveChange = newValue }
  }

  /// Asked to bring the watch screen back; must call the handler with `true` once it is shown.
  var onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)? {
    get { pipDelegate.onRestore }
    set { pipDelegate.onRestore = newValue }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    playerLayer.videoGravity = .resizeAspect
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError() }

  func attach(_ player: AVPlayer) {
    playerLayer.player = player
  }

  /// Detaches the player while backgrounded without PiP so audio keeps playing.
  func detachForBackground() { playerLayer.player = nil }

  func setUpPictureInPicture(autoStart: Bool) {
    guard pipController == nil, AVPictureInPictureController.isPictureInPictureSupported() else {
      pipController?.canStartPictureInPictureAutomaticallyFromInline = autoStart
      return
    }
    let controller = AVPictureInPictureController(playerLayer: playerLayer)
    controller?.delegate = pipDelegate
    controller?.canStartPictureInPictureAutomaticallyFromInline = autoStart
    pipController = controller
  }

  func tearDownPictureInPicture() {
    pipController?.stopPictureInPicture()
    pipController?.delegate = nil
    pipController = nil
  }

  var isPictureInPicturePossible: Bool { pipController?.isPictureInPicturePossible ?? false }
  var isPictureInPictureActive: Bool { pipController?.isPictureInPictureActive ?? false }

  func togglePictureInPicture() {
    guard let pipController else { return }
    if pipController.isPictureInPictureActive {
      pipController.stopPictureInPicture()
    } else {
      pipController.startPictureInPicture()
    }
  }
}

final class PiPDelegate: NSObject, AVPictureInPictureControllerDelegate {
  var onActiveChange: ((Bool) -> Void)?
  var onRestore: ((@escaping (Bool) -> Void) -> Void)?

  nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated { onActiveChange?(true) }
  }

  nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    MainActor.assumeIsolated { onActiveChange?(false) }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: any Error
  ) {
    MainActor.assumeIsolated { onActiveChange?(false) }
  }

  nonisolated func pictureInPictureController(
    _ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    MainActor.assumeIsolated {
      if let onRestore {
        onRestore(completionHandler)
      } else {
        completionHandler(true)
      }
    }
  }
}

/// Container that adopts the shared surface while `isActive`.
final class PlayerHostView: UIView {
  weak var surface: PlayerSurfaceView?
  var isActive = false {
    didSet { claimIfPossible() }
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    claimIfPossible()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if let surface, surface.superview === self { surface.frame = bounds }
  }

  func claimIfPossible() {
    guard isActive, window != nil, let surface, surface.superview !== self else { return }
    surface.removeFromSuperview()
    surface.frame = bounds
    surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    addSubview(surface)
  }
}

/// SwiftUI host for the shared player surface.
struct PlayerLayerView: UIViewRepresentable {
  let engine: PlayerEngine
  var isActive: Bool = true

  func makeUIView(context: Context) -> PlayerHostView {
    let host = PlayerHostView()
    host.backgroundColor = .clear
    host.surface = engine.surface
    engine.register(host)
    host.isActive = isActive
    return host
  }

  func updateUIView(_ host: PlayerHostView, context: Context) {
    host.isActive = isActive
  }

  static func dismantleUIView(_ host: PlayerHostView, coordinator: ()) {
    host.isActive = false
    host.surface?.engine?.unregister(host)
  }
}
