import Foundation
import Speech
import AVFoundation
import Observation

/// Hands-free control: listens for "next", "back", "repeat", "parts" and "done".
/// Uses on-device speech recognition when the device supports it.
@MainActor
@Observable
final class VoiceCommands {
    enum Command { case next, back, repeatStep, parts, finish }

    private(set) var isListening = false
    private(set) var lastHeard = ""
    private(set) var status = ""

    @ObservationIgnored var onCommand: ((Command) -> Void)?
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var fired = Set<String>()

    func toggle() async {
        if isListening { stop() } else { await start() }
    }

    func start() async {
        let speechAllowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
        guard speechAllowed else { status = "Allow speech recognition in Settings"; return }
        #if os(iOS)
        let micAllowed = await AVAudioApplication.requestRecordPermission()
        #else
        let micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
        #endif
        guard micAllowed else { status = "Allow the microphone in Settings"; return }
        guard recognizer?.isAvailable == true else { status = "Speech recognition is unavailable right now"; return }
        do {
            isListening = true
            try begin()
            status = "Say “next”, “back” or “repeat”"
        } catch {
            status = "Voice control failed: \(error.localizedDescription)"
            stop()
        }
    }

    func stop() {
        isListening = false
        tearDown()
        status = ""
    }

    private func tearDown() {
        generation += 1
        if engine.isRunning { engine.stop() }
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
    }

    private func begin() throws {
        tearDown()
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer?.supportsOnDeviceRecognition == true { request.requiresOnDeviceRecognition = true }
        request.contextualStrings = ["next", "back", "repeat", "previous", "again", "parts", "done"]
        self.request = request
        fired.removeAll()

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { @Sendable buffer, _ in
            request.append(buffer)
        }
        engine.prepare()
        try engine.start()

        let current = generation
        task = recognizer?.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let words = result?.bestTranscription.segments.map { $0.substring.lowercased() } ?? []
            let finished = (result?.isFinal ?? false) || error != nil
            Task { @MainActor [weak self] in
                guard let self, self.generation == current else { return }
                self.process(words)
                if finished || words.count > 40 { self.restart() }
            }
        }
    }

    private func restart() {
        guard isListening else { return }
        tearDown()
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, self.isListening else { return }
            do { try self.begin() } catch { self.stop() }
        }
    }

    /// Partial results keep revising the last word, so check the last two words and
    /// remember which (position, command) pairs already fired.
    private func process(_ words: [String]) {
        guard !words.isEmpty else { return }
        for index in max(0, words.count - 2) ..< words.count {
            let word = words[index].trimmingCharacters(in: .punctuationCharacters)
            guard let command = Self.command(for: word) else { continue }
            let key = "\(index)-\(word)"
            guard !fired.contains(key) else { continue }
            fired.insert(key)
            lastHeard = word
            onCommand?(command)
        }
    }

    private static func command(for word: String) -> Command? {
        switch word {
        case "next", "forward", "continue": return .next
        case "back", "previous", "undo": return .back
        case "repeat", "again", "replay": return .repeatStep
        case "parts", "pieces": return .parts
        case "done", "finish", "finished": return .finish
        default: return nil
        }
    }
}
