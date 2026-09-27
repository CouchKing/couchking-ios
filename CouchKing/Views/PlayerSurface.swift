import SwiftUI
import AVKit

// Video surface + Picture-in-Picture (pop-out). The player renders into a plain AVPlayerLayer
// (not AVPlayerViewController / SwiftUI VideoPlayer) so an AVPictureInPictureController can be
// attached to it and started from our own top-corner button. Our overlay supplies every control.

/// A UIView whose backing layer IS the AVPlayerLayer (resizes with the view, no manual frames).
final class PlayerLayerView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

/// Owns the PiP controller for one player surface and publishes whether PiP is possible
/// (the item must be ready) and whether the pop-out is currently showing.
@MainActor
final class PiPModel: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    @Published var possible = false
    @Published var active = false
    private var controller: AVPictureInPictureController?
    private var possibleObs: NSKeyValueObservation?

    /// False on devices without PiP (the button is hidden there).
    static var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    func attach(_ layer: AVPlayerLayer) {
        guard controller == nil, Self.supported,
              let c = AVPictureInPictureController(playerLayer: layer) else { return }
        // swiping home / locking mid-playback pops the video out automatically
        c.canStartPictureInPictureAutomaticallyFromInline = true
        c.delegate = self
        controller = c
        possibleObs = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let p = c.isPictureInPicturePossible
            Task { @MainActor in self?.possible = p }
        }
    }

    /// The top-corner button: pop out, or bring the video back in.
    func toggle() {
        guard let c = controller else { return }
        if c.isPictureInPictureActive { c.stopPictureInPicture() } else { c.startPictureInPicture() }
    }

    func stop() {
        if let c = controller, c.isPictureInPictureActive { c.stopPictureInPicture() }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.active = true }
    }
    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
        Task { @MainActor in self.active = false }
    }
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        Task { @MainActor in self.active = false }
    }
    /// Tapping "back to app" in the PiP window: the player screen is still presented underneath,
    /// so the full-screen UI is already there — just tell the system it's restored.
    nonisolated func pictureInPictureController(_ c: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}

/// The video surface: AVPlayerLayer with the aspect-cycle gravity, PiP attached on creation.
struct PlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let gravity: AVLayerVideoGravity
    let pip: PiPModel

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        pip.attach(v.playerLayer)
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        if v.playerLayer.videoGravity != gravity { v.playerLayer.videoGravity = gravity }
    }
}

/// Audio session for video: `.playback` keeps sound going with the ringer switch on silent,
/// with the screen locked, in the background, and in the PiP window (needs UIBackgroundModes
/// audio, already in project.yml).
enum PlaybackAudio {
    static func configure() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
    }
    static func activate() {
        configure()
        try? AVAudioSession.sharedInstance().setActive(true)
    }
}
