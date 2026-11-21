import AVFoundation

/// The soft click when a piece seats. Quiet on purpose, and silent when the phone is muted.
@MainActor
final class ClickSound {
    static let shared = ClickSound()
    private var player: AVAudioPlayer?

    private init() {
        let bundle = Bundle.main
        guard let url = bundle.url(forResource: "click", withExtension: "wav")
            ?? bundle.url(forResource: "click", withExtension: "wav", subdirectory: "Sounds") else { return }
        #if os(iOS)
        // Mix with whatever is already playing instead of stopping it.
        let session = AVAudioSession.sharedInstance()
        if session.category == .soloAmbient { try? session.setCategory(.ambient) }
        #endif
        player = try? AVAudioPlayer(contentsOf: url)
        player?.volume = 0.35
        player?.prepareToPlay()
    }

    func play() {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }
}
