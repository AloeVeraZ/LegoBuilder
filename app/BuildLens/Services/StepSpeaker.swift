import AVFoundation

/// Reads steps out loud (useful hands-free, and the same text will go to the glasses).
@MainActor
final class StepSpeaker: NSObject, AVAudioPlayerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    /// The most natural voice on this device: a premium or enhanced one if the owner has
    /// downloaded any (Settings > Accessibility > Spoken Content > Voices), else the best
    /// of the built-in ones.
    private lazy var voice: AVSpeechSynthesisVoice? = {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        func score(_ v: AVSpeechSynthesisVoice) -> Int {
            var points = v.quality == .premium ? 300 : v.quality == .enhanced ? 200 : 0
            if v.language == "en-US" { points += 50 }
            // Of the built-in ones, these read the most naturally.
            if ["Samantha", "Ava", "Zoe", "Evan", "Nathan", "Joelle"].contains(where: v.name.contains) { points += 20 }
            // The novelty and old robotic voices are never what anyone wants here.
            if v.identifier.contains("eloquence") || v.identifier.contains("speech.synthesis.voice") { points -= 500 }
            return points
        }
        return english.max { score($0) < score($1) } ?? AVSpeechSynthesisVoice(language: "en-US")
    }()

    private var player: AVAudioPlayer?
    /// The line asked for while another was still being said: it follows once that one ends
    /// (only the latest is kept), so a line is never cut off by the next.
    private var waiting: (text: String, recording: URL?)?

    /// Plays the recording of a line (a real voice), or reads the words out with the
    /// phone's own voice when there is no recording. Waits for the line being said to end.
    func say(_ text: String, recording: URL?) {
        if player?.isPlaying ?? false { waiting = (text, recording); return }
        guard let recording, let player = try? AVAudioPlayer(contentsOf: recording) else { return say(text) }
        stop()
        prepareSession()
        player.delegate = self
        self.player = player
        player.play()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            guard player === self.player else { return }
            self.player = nil
            if let next = self.waiting { self.waiting = nil; self.say(next.text, recording: next.recording) }
        }
    }

    /// How long a recording takes to say (0 if there is none).
    static func duration(of recording: URL?) -> TimeInterval {
        guard let recording, let player = try? AVAudioPlayer(contentsOf: recording) else { return 0 }
        return player.duration
    }

    private func prepareSession() {
        #if os(iOS)
        // Without this the phone's silent switch mutes the reading. If voice control has the
        // microphone open it has already set the session up for both, so leave that alone.
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord {
            try? session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try? session.setActive(true)
        }
        #endif
    }

    func say(_ text: String) {
        guard !text.isEmpty else { return }
        player?.stop()
        player = nil
        prepareSession()
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice
        // A touch slower and lower than the default, which is what makes it sound rushed.
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.94
        utterance.pitchMultiplier = 0.98
        utterance.postUtteranceDelay = 0.1
        synthesizer.speak(utterance)
    }

    /// True while a step is being read out. Voice commands are ignored meanwhile, because the
    /// microphone hears the speaker and the spoken text contains words like "next" and "done".
    var isSpeaking: Bool { synthesizer.isSpeaking || (player?.isPlaying ?? false) }

    func stop() {
        waiting = nil
        player?.stop()
        player = nil
        synthesizer.stopSpeaking(at: .immediate)
    }
}
