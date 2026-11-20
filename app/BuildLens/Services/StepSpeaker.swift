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

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
