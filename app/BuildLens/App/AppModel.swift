import SwiftUI
import Observation

enum ARPhase {
    case scanning   // looking for the box
    case revealed   // finished model shown, waiting for "Start building"
    case building   // following the steps
}

/// App-wide state: the loaded build, the current step and the helpers around it.
@MainActor
@Observable
final class AppModel {
    private(set) var model: BuildModel?
    private(set) var scene: BuildScene?
    private(set) var orbit: OrbitController?
    private(set) var loadError: String?
    private(set) var loadingProgress: Double = 0

    private(set) var step = 0
    private(set) var showingFinished = false
    var arPhase: ARPhase = .scanning
    var needsRescan = false
    private(set) var foundByScan = false
    private(set) var syncPeers: [String] = []
    private(set) var glassesConnected = false

    var focusMode = false {
        didSet {
            scene?.dimPrevious = focusMode
            scene?.refresh()
        }
    }
    var readAloud = false {
        didSet { if readAloud { speakCurrent() } else { speaker.stop() } }
    }

    let voice: VoiceCommands
    let speaker: StepSpeaker
    let sync: PeerSync
    let glasses: GlassesLink

    init() {
        voice = VoiceCommands()
        speaker = StepSpeaker()
        sync = PeerSync()
        glasses = GlassesLink()
    }

    var stepCount: Int { model?.steps.count ?? 0 }
    var currentStep: BuildModel.StepInfo? {
        guard let model, step < model.steps.count else { return nil }
        return model.steps[step]
    }
    var progress: Double { stepCount == 0 ? 0 : Double(step + 1) / Double(stepCount) }

    // MARK: loading

    func load() async {
        guard model == nil, loadError == nil else { return }
        do {
            let model = try BuildModel.loadBundled()
            let scene = BuildScene(model: model)
            try await scene.prepare { [weak self] value in self?.loadingProgress = value }
            scene.showFinished(animated: false)
            self.model = model
            self.scene = scene
            self.orbit = OrbitController(scene: scene)

            sync.onRemoteStep = { [weak self] index in self?.go(to: index, broadcast: false) }
            sync.onPeersChanged = { [weak self] names in self?.syncPeers = names }
            sync.start()
            glasses.onConnectionChange = { [weak self] connected in self?.glassesConnected = connected }
            glasses.onRemoteStep = { [weak self] index, finished in
                guard let self else { return }
                if finished { if !self.showingFinished { self.finish() } } else { self.go(to: index) }
            }
            glasses.start()
            voice.onCommand = { [weak self] command in self?.handle(command) }
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: flow

    /// Opening the camera: start by looking for the box.
    func beginScanning() {
        arPhase = .scanning
        needsRescan = true
        foundByScan = false
        scene?.showFinished(animated: false)
    }

    /// The AR view found the box (or the user tapped a table).
    func didPlaceModel(found: Bool) {
        foundByScan = found
        arPhase = .revealed
        showingFinished = false
        scene?.showFinished(animated: false)
        Haptics.success()
        if readAloud, let model {
            speaker.say("Found \(model.name). \(model.pieceCount) pieces in \(model.steps.count) steps.")
        }
    }

    /// Opening the 3D viewer goes straight to the steps.
    func enterViewer() {
        if arPhase != .building { arPhase = .building }
        go(to: step, broadcast: false, force: true)
    }

    func startBuilding() {
        arPhase = .building
        go(to: step, force: true)
    }

    func next() {
        if step + 1 < stepCount { go(to: step + 1) } else { finish() }
    }

    func back() {
        if showingFinished { go(to: step, force: true) } else if step > 0 { go(to: step - 1) }
    }

    func replay() {
        showingFinished = false
        scene?.show(step: step, animated: true, force: true)
        speakCurrent()
    }

    func restart() {
        go(to: 0, force: true)
    }

    func finish() {
        showingFinished = true
        scene?.showFinished(animated: true)
        glasses.send(step: step, finished: true)
        Haptics.success()
        if readAloud, let model { speaker.say("You built the \(model.name)!") }
    }

    func go(to index: Int, broadcast: Bool = true, force: Bool = false) {
        guard let model, index >= 0, index < model.steps.count else { return }
        let changed = index != step || showingFinished
        step = index
        showingFinished = false
        if arPhase != .building { arPhase = .building }
        scene?.show(step: index, animated: changed || force, force: changed || force)
        if changed { Haptics.tap() }
        if broadcast { sync.send(step: index) }
        glasses.send(step: index, finished: false)
        if changed || force { speakCurrent() }
    }

    private func speakCurrent() {
        guard readAloud, let model, !showingFinished else { return }
        speaker.say(model.spokenSummary(for: step))
    }

    private func handle(_ command: VoiceCommands.Command) {
        switch command {
        case .next: next()
        case .back: back()
        case .repeatStep: replay()
        case .finish: finish()
        case .parts:
            if let model { speaker.say(model.spokenSummary(for: step)) }
        }
    }
}
