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
    /// AR has just been opened and is still looking for the table: nothing of the build
    /// is shown until the model is standing on it.
    var arFindingSurface = false
    /// AR: the cube in the corner that turns the model and puts it back.
    let viewCube = ViewCubeModel()
    private(set) var foundByScan = false
    private(set) var syncPeers: [String] = [] {
        didSet { keepAwake.linked = !syncPeers.isEmpty || glassesConnected }
    }
    /// Keeps the phone awake and running (also in the background) while it is linked.
    @ObservationIgnored let keepAwake = KeepAwake()
    private(set) var glassesConnected = false
    /// The glasses asked for the phone's code (they are scanning): the Table marker goes up
    /// by itself, from wherever the app is. Back to false when it is closed.
    var markerRequested = false
    /// The glasses have placed the build: the phone puts its code away and opens the steps.
    var openInstructionsRequested = false

    private func glassesPlaced() {
        #if os(macOS)
        sync.sendPlaced()                      // on to the phone
        #else
        markerRequested = false
        openInstructionsRequested = true
        #endif
    }
    /// The set's box has been scanned at the start (BoxScanView); until then nothing else shows.
    /// The model's turn as seen (degrees about its upright, 0 = front towards the viewer) and
    /// zoom (1 = as framed), the same on phone, Mac and glasses.
    private(set) var modelSpin: Double = 0
    private(set) var modelZoom: Double = 1
    /// How far the view leans to look from above, in degrees (3D view only; nil until turned).
    @ObservationIgnored private var modelTilt: Double?
    @ObservationIgnored private var lastViewSent = Date.distantPast
    @ObservationIgnored private var viewSendLater: Task<Void, Never>?

    /// Turned or zoomed by hand here: shown on the others too (at most about 30 times a second,
    /// the last one always sent).
    func userTurned(spin: Double, zoom: Double?, tilt: Double? = nil) {
        keepAwake.touch()
        modelSpin = spin
        if let zoom { modelZoom = zoom }
        if let tilt { modelTilt = tilt }
        sendView(toPhone: true, toGlasses: true)
    }

    /// Turned or zoomed on the phone (sync) or the glasses (link). The Mac passes it on to
    /// the other one.
    private func remoteView(spin: Double, zoom: Double?, tilt: Double?, fromGlasses: Bool) {
        keepAwake.touch()
        linkLog.debug("view from \(fromGlasses ? "glasses" : "phone", privacy: .public): spin \(spin) zoom \(zoom ?? -1)")
        modelSpin = spin
        if let zoom { modelZoom = zoom }
        if let tilt { modelTilt = tilt }
        orbit?.apply(spin: spin, zoom: zoom, tilt: tilt)
        #if os(macOS)
        sendView(toPhone: fromGlasses, toGlasses: !fromGlasses)
        #endif
    }

    private func sendView(toPhone: Bool, toGlasses: Bool) {
        viewSendLater?.cancel()
        let send = { [weak self] in
            guard let self else { return }
            self.lastViewSent = Date()
            if toPhone { self.sync.sendView(spin: self.modelSpin, zoom: self.modelZoom, tilt: self.modelTilt) }
            if toGlasses {
                linkLog.debug("view to glasses: spin \(self.modelSpin) zoom \(self.modelZoom)")
                self.glasses.sendView(spin: self.modelSpin, zoom: self.modelZoom, tilt: self.modelTilt)
            }
        }
        let wait = 0.033 - Date().timeIntervalSince(lastViewSent)
        if wait <= 0 { send(); return }
        viewSendLater = Task { @MainActor in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled else { return }
            send()
        }
    }

    /// Scanning it on any one device (phone, Mac or glasses' own camera) counts for all of them:
    /// it is passed on to the others (PeerSync, the glasses link).
    var setScanned = false {
        didSet {
            guard setScanned, !oldValue else { return }
            sync.sendBoxScanned()
            glasses.sendBoxScanned()
            #if os(iOS)
            // The phone leads at the start: straight on to the table marker, for the glasses
            // to find. Once they have, they take over and the phone just lies there as the marker.
            markerRequested = true
            #endif
        }
    }
    /// The box scan was closed with its X: home without scanning (the scan is still offered there).
    var skippedBoxScan = false
    /// The Mac: the glasses on its cable last said they are scanning, so a phone that links
    /// later is asked for the marker too.
    private var glassesScanning = false

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

    // The two switches in the ••• menu are remembered between launches.
    var focusMode = UserDefaults.standard.bool(forKey: "fadeBuiltPieces") {
        didSet {
            UserDefaults.standard.set(focusMode, forKey: "fadeBuiltPieces")
            scene?.dimPrevious = focusMode
            scene?.refresh()
            sendSettings()
        }
    }
    /// The voices to read steps in, by name, with their recordings' file prefix
    /// (pipeline/make_voice.py VOICES). Original voices from the Kokoro model.
    static let voices: [(name: String, prefix: String)] = [("Heart", ""), ("Onyx", "onyx-")]
    var voiceName = UserDefaults.standard.string(forKey: "voiceName") ?? "Heart" {
        didSet {
            UserDefaults.standard.set(voiceName, forKey: "voiceName")
            sendSettings()
            if readAloud { speakCurrent() }
        }
    }
    private var voicePrefix: String { Self.voices.first { $0.name == voiceName }?.prefix ?? "" }

    /// Settings are made on the phone; the glasses follow them (through the Mac, or directly).
    func sendSettings() {
        sync.sendSettings(fade: focusMode, voice: voicePrefix, aloud: readAloud)
        glasses.sendSettings(fade: focusMode, voice: voicePrefix, aloud: readAloud)
    }

    /// A setting changed on the glasses' menu: the same here (which sends it on, unchanged
    /// values going no further).
    private func settingsFromGlasses(fade: Bool, voice: String, aloud: Bool) {
        #if os(macOS)
        sync.sendSettings(fade: fade, voice: voice, aloud: aloud)   // on to the phone
        #else
        if focusMode != fade { focusMode = fade }
        if readAloud != aloud { readAloud = aloud }
        if let name = Self.voices.first(where: { $0.prefix == voice })?.name, voiceName != name { voiceName = name }
        #endif
    }

    /// The glasses are on the other end (directly, or plugged into the Mac): they read the
    /// steps through their own speaker, and the phone stays quiet so it isn't said twice.
    private var glassesThroughMac = false
    private var glassesSpeak: Bool { glassesConnected || glassesThroughMac }

    var readAloud = UserDefaults.standard.bool(forKey: "readStepsAloud") {
        didSet {
            UserDefaults.standard.set(readAloud, forKey: "readStepsAloud")
            sendSettings()
            if readAloud { speakCurrent() } else { speaker.stop() }
        }
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
            scene.dimPrevious = focusMode           // as it was left last time
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
                #if os(macOS)
                // The Mac in the middle: the phone's step goes on to the glasses on the cable.
                self.glasses.send(step: index, finished: false)
                #endif
                if self.glasses.instructionsOpen { self.go(to: index, broadcast: false) } else { self.remember(step: index) }
            }
            sync.onPeersChanged = { [weak self] names in
                guard let self else { return }
                self.syncPeers = names
                if self.setScanned, !names.isEmpty { self.sync.sendBoxScanned() }
                #if os(macOS)
                if !names.isEmpty { self.sync.sendGlassesPresent(self.glassesConnected) }
                #endif
                #if os(iOS)
                if !names.isEmpty { self.sendSettings() }
                #endif
                #if os(macOS)
                if self.glassesScanning, !names.isEmpty { self.sync.sendScanRequest() }
                #endif
            }
            // The glasses (through the Mac) ask for the Table marker.
            sync.onScanRequest = { [weak self] in self?.markerRequested = true }
            sync.onBoxScanned = { [weak self] in self?.setScanned = true }
            #if os(macOS)
            // The phone's settings, on to the glasses.
            sync.onSettings = { [weak self] fade, voice, aloud in self?.glasses.sendSettings(fade: fade, voice: voice ?? "", aloud: aloud) }
            #else
            // The glasses' menu, through the Mac.
            sync.onSettings = { [weak self] fade, voice, aloud in self?.settingsFromGlasses(fade: fade, voice: voice ?? "", aloud: aloud) }
            sync.onGlassesThroughMac = { [weak self] present in
                self?.glassesThroughMac = present
                if present { self?.speaker.stop() }
            }
            #endif
            sync.onPlaced = { [weak self] in self?.glassesPlaced() }
            glasses.onPlaced = { [weak self] in self?.glassesPlaced() }
            glasses.onSettings = { [weak self] fade, voice, aloud in self?.settingsFromGlasses(fade: fade, voice: voice, aloud: aloud) }
            sync.onRemoteView = { [weak self] spin, zoom, tilt in self?.remoteView(spin: spin, zoom: zoom, tilt: tilt, fromGlasses: false) }
            glasses.onRemoteView = { [weak self] spin, zoom, tilt in self?.remoteView(spin: spin, zoom: zoom, tilt: tilt, fromGlasses: true) }
            orbit.onUserTurn = { [weak self] spin, zoom, tilt in self?.userTurned(spin: spin, zoom: zoom, tilt: tilt) }
            glasses.onBoxScanned = { [weak self] in self?.setScanned = true }
            sync.start()
            glasses.onConnectionChange = { [weak self] connected in
                guard let self else { return }
                self.glassesConnected = connected
                self.keepAwake.linked = !self.syncPeers.isEmpty || connected
                #if os(macOS)
                self.sync.sendGlassesPresent(connected)  // so the phone knows the glasses speak
                #endif
                if connected, self.setScanned { self.glasses.sendBoxScanned() }
                #if os(iOS)
                if connected { self.sendSettings() }
                #endif
            }
            // A click on the glasses. They already show the result, so nothing is sent back
            // (an echo arriving late could pull them back a step).
            glasses.onRemoteStep = { [weak self] index, finished, replay in
                guard let self else { return }
                #if os(macOS)
                // The Mac in the middle: a click on the glasses goes on to the phone. A click
                // means they are building, so no longer scanning.
                self.glassesScanning = false
                if !finished { self.sync.send(step: index) }
                #endif
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
            // The glasses are looking for the phone's code: put it up on the phone.
            glasses.onScanRequest = { [weak self] in
                guard let self else { return }
                #if os(macOS)
                self.glassesScanning = true
                self.sync.sendScanRequest()        // on to the phone
                #else
                self.markerRequested = true
                #endif
            }
            glasses.onHello = { [weak self] index, finished in
                guard let self, !self.glasses.instructionsOpen, !finished, index > 0 else { return }
                self.remember(step: index)
            }
            // The phone links to the glasses over Wi-Fi when both are on it. The Mac links to
            // glasses plugged into its USB cable and passes steps between them and the phone.
            #if os(iOS)
            glasses.start()
            #else
            // The Mac reaches glasses plugged into its USB cable and passes steps between them
            // and the phone, so the phone and glasses need no Wi-Fi link of their own.
            glasses.startUSB()
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
            speak("found", otherwise: "Found \(model.name). \(model.pieceCount) pieces in \(model.steps.count) steps.")
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
            if self.readAloud { self.speak(String(format: "done-%03d", self.step + 1), otherwise: "\(message.title) \(message.detail)") }
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

    /// The last piece of a part of the build (or of the whole truck) is clicking in, or the
    /// "well done" for it is up: the step itself is over. The glasses preview follows this.
    var isSeating: Bool { milestoneTask != nil || finishTask != nil }

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
        speaker.stop()
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
            if self.readAloud, let model = self.model { self.speak("finish", otherwise: "You built the \(model.name)!") }
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
        speak(String(format: "step-%03d", step + 1), otherwise: model.spokenSummary(for: step))
    }

    /// Says a line: its recording if there is one, else its words in the phone's own voice.
    private func speak(_ key: String, otherwise: String) {
        if glassesSpeak { return }
        guard let model else { return speaker.say(otherwise) }
        speaker.say(model.spokenLines[key] ?? otherwise, recording: model.recording(key, voice: voicePrefix))
    }

    /// Stops whatever is being said, at once (leaving the instructions, or changing view).
    /// The next step, or Replay, starts it again.
    func hush() {
        speaker.stop()
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
