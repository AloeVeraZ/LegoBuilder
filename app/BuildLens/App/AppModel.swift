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
    /// AR: the user asked to stand the model on a flat surface. Stays true while the
    /// camera looks for one, and goes false once the model is sitting on it.
    var placingOnSurface = false
    /// AR: the cube in the corner that turns the model and puts it back.
    let viewCube = ViewCubeModel()
    private(set) var foundByScan = false
    private(set) var syncPeers: [String] = []
    private(set) var glassesConnected = false

    /// A short "well done" between parts of the build (a sub-build finished, or the next
    /// one about to start). Shown for a moment, then the build moves on by itself.
    struct Milestone: Equatable {
        let title: String
        let detail: String
    }
    private(set) var milestone: Milestone?
    private var milestoneTask: Task<Void, Never>?
    private var isLoading = false
    private var finishTask: Task<Void, Never>?

    /// What the current step is part of: the main build, or a sub-build made on the side.
    var sectionTitle: String {
        guard let current = currentStep, current.isSubAssembly else { return "Main build" }
        let name = current.assembly.name
        return current.assembly.uses > 1 ? "Sub-build · \(name) ×\(current.assembly.uses)" : "Sub-build · \(name)"
    }
    var isSubBuild: Bool { currentStep?.isSubAssembly ?? false }

    /// The side the model was last turned to by hand, until the step changes.
    private(set) var userView: Int?
    /// The side the glasses show the current step from.
    var glassesView: Int { userView ?? currentStep?.view ?? 0 }

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
        // More than one window can ask; only the first does the work.
        guard model == nil, loadError == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let model = try BuildModel.loadBundled()
            let scene = BuildScene(model: model)
            try await scene.prepare { [weak self] value in self?.loadingProgress = value }
            scene.showFinished(animated: false)
            self.model = model
            self.scene = scene
            let orbit = OrbitController(scene: scene)
            self.orbit = orbit
            // Turning the model by hand: the glasses switch to the same side.
            orbit.onUserView = { [weak self] view in
                guard let self, !self.showingFinished, view != self.glassesView else { return }
                self.userView = view
                self.glasses.send(step: self.step, finished: false, view: view)
            }

            sync.onRemoteStep = { [weak self] index in
                guard let self else { return }
                if self.glasses.instructionsOpen { self.go(to: index, broadcast: false) } else { self.remember(step: index) }
            }
            sync.onPeersChanged = { [weak self] names in self?.syncPeers = names }
            sync.start()
            glasses.onConnectionChange = { [weak self] connected in self?.glassesConnected = connected }
            // A click on the glasses. They already show the result, so nothing is sent back
            // (an echo arriving late could pull them back a step).
            glasses.onRemoteStep = { [weak self] index, finished, replay in
                guard let self else { return }
                guard self.glasses.instructionsOpen else {
                    // The phone is on its home screen or still scanning: just keep our place
                    // in step with the glasses, without touching what is on screen.
                    if !finished { self.remember(step: index) }
                    return
                }
                if finished {
                    if !self.showingFinished { self.finish(tellGlasses: false) }
                } else if replay, index == self.step {
                    self.replay(broadcast: false)
                } else if index == self.step + 1, !self.showingFinished, self.milestoneTask == nil,
                          let message = self.milestone(after: self.step) {
                    // The glasses moved on past the end of a part of the build: they are
                    // showing their own "good job", so the phone does the same.
                    self.celebrate(message, tellGlasses: false)
                } else if index != self.step || self.showingFinished || self.finishTask != nil {
                    self.go(to: index, tellGlasses: false)
                }
            }
            // Glasses that are part-way through a build when we link: keep our place with
            // theirs, unless the instructions are open here (then the phone leads).
            glasses.onHello = { [weak self] index, finished in
                guard let self, !self.glasses.instructionsOpen, !finished, index > 0 else { return }
                self.remember(step: index)
            }
            // Only the phone drives the glasses. The Mac app is for showing the build on a
            // big screen; it follows the phone, and its Glasses preview window shows what the
            // glasses show.
            #if os(iOS)
            glasses.start()
            #endif
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
        glasses.instructionsOpen = true         // the glasses bring their screen up by themselves
        go(to: step, broadcast: false, force: true)
    }

    func startBuilding() {
        arPhase = .building
        glasses.instructionsOpen = true
        go(to: step, force: true)
    }

    func next() {
        // Next during the "well done" moment skips the wait.
        if milestoneTask != nil { return advancePastMilestone() }
        guard step + 1 < stepCount else { return finish() }
        if let milestone = milestone(after: step) {
            celebrate(milestone)
        } else {
            go(to: step + 1)
        }
    }

    func back() {
        if milestoneTask != nil || finishTask != nil {
            clearMilestone()
            go(to: step, force: true)
        } else if showingFinished {
            go(to: step, force: true)
        } else if step > 0 {
            go(to: step - 1)
        }
    }

    /// The message for leaving `index`, if the next step belongs to a different part of the build.
    private func milestone(after index: Int) -> Milestone? {
        guard let model, index + 1 < model.steps.count else { return nil }
        let here = model.steps[index], coming = model.steps[index + 1]
        guard here.assembly.id != coming.assembly.id else { return nil }
        if here.isSubAssembly {
            let detail = here.assembly.uses > 1
                ? "Make \(here.assembly.uses) of these. Then they go on the truck."
                : "Nice work. Now it goes on the truck."
            return Milestone(title: "\(here.assembly.name) done!", detail: detail)
        }
        return Milestone(title: "Good job!", detail: "Set this part aside. Next: the \(coming.assembly.name.lowercased()).")
    }

    /// The last piece is pushed home, then the card shows for two seconds, goes away, and
    /// only then does the next part of the build appear.
    private func celebrate(_ message: Milestone, tellGlasses: Bool = true) {
        let settle = scene?.seatWaiting() ?? 0
        if tellGlasses { glasses.send(step: step, finished: false, milestone: true) }
        milestoneTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.milestone = message
            Haptics.success()
            if self.readAloud { self.speaker.say("\(message.title) \(message.detail)") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self.milestone = nil
            try? await Task.sleep(nanoseconds: 450_000_000)
            guard !Task.isCancelled else { return }
            self.advancePastMilestone()
        }
    }

    private func advancePastMilestone() {
        clearMilestone()
        go(to: step + 1)
    }

    private func clearMilestone() {
        milestoneTask?.cancel()
        milestoneTask = nil
        milestone = nil
    }

    func replay(broadcast: Bool = true) {
        clearMilestone()
        finishTask?.cancel()
        finishTask = nil
        showingFinished = false
        scene?.show(step: step, animated: true, force: true)
        if broadcast { glasses.send(step: step, finished: false, replay: true) }
        speakCurrent()
    }

    func restart() {
        go(to: 0, force: true)
    }

    /// Dragging the step slider: show each step it passes at once, with no animation,
    /// sound or network traffic, so the drag never lags behind the finger.
    func scrub(to index: Int) {
        guard let model, index >= 0, index < model.steps.count, index != step || showingFinished else { return }
        clearMilestone()
        finishTask?.cancel()
        finishTask = nil
        step = index
        showingFinished = false
        scene?.show(step: index, animated: false, force: true)
    }

    /// Letting go of the slider: now play the step properly and tell the other devices.
    func endScrub() {
        go(to: step, force: true)
    }

    /// Closing the instructions. A finished build starts from step 1 the next time;
    /// anything else picks up where it was left. The glasses keep showing what they show.
    func leaveInstructions() {
        glasses.instructionsOpen = false
        clearMilestone()
        let wasFinishing = finishTask != nil
        finishTask?.cancel()
        finishTask = nil
        if showingFinished || wasFinishing {
            step = 0
            showingFinished = false
        }
    }

    /// The last pieces are pushed home first; "You built it" only appears once they are in.
    func finish(tellGlasses: Bool = true) {
        guard !showingFinished, finishTask == nil else { return }
        clearMilestone()
        let settle = scene?.showFinished(animated: true) ?? 0
        if tellGlasses { glasses.send(step: step, finished: true) } else { glasses.note(step: step, finished: true) }
        finishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(settle * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            self.finishTask = nil
            self.showingFinished = true
            self.scene?.spin()
            Haptics.success()
            if self.readAloud, let model = self.model { self.speaker.say("You built the \(model.name)!") }
        }
    }

    /// Keeps our place without changing what is on screen (the instructions are not open).
    private func remember(step index: Int) {
        guard let model, index >= 0, index < model.steps.count else { return }
        step = index
        showingFinished = false
    }

    func go(to index: Int, broadcast: Bool = true, force: Bool = false, tellGlasses: Bool = true) {
        guard let model, index >= 0, index < model.steps.count else { return }
        clearMilestone()
        finishTask?.cancel()
        finishTask = nil
        let changed = index != step || showingFinished
        if changed || force { userView = nil }
        step = index
        showingFinished = false
        if arPhase != .building { arPhase = .building }
        scene?.show(step: index, animated: changed || force, force: changed || force)
        if changed { Haptics.tap() }
        if broadcast { sync.send(step: index) }
        if tellGlasses { glasses.send(step: index, finished: false) } else { glasses.note(step: index, finished: false) }
        if changed || force { speakCurrent() }
    }

    private func speakCurrent() {
        guard readAloud, let model, !showingFinished else { return }
        speaker.say(model.spokenSummary(for: step))
    }

    private func handle(_ command: VoiceCommands.Command) {
        // The microphone hears our own read-aloud, which says "next" and "done".
        guard !speaker.isSpeaking else { return }
        switch command {
        case .next: next()
        case .back: back()
        case .repeatStep: replay()
        case .finish: if step + 1 == stepCount { finish() }
        case .parts:
            if let model { speaker.say(model.spokenSummary(for: step)) }
        }
    }
}
