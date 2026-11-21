import AVFoundation

/// Reads steps out loud (useful hands-free, and the same text will go to the glasses).
@MainActor
final class StepSpeaker {
    private let synthesizer = AVSpeechSynthesizer()

    func say(_ text: String) {
        guard !text.isEmpty else { return }
        synthesizer.stopSpeaking(at: .immediate)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        synthesizer.speak(utterance)
    }

    /// True while a step is being read out. Voice commands are ignored meanwhile, because the
    /// microphone hears the speaker and the spoken text contains words like "next" and "done".
    var isSpeaking: Bool { synthesizer.isSpeaking }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
