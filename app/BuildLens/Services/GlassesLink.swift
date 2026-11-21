import Foundation
import Network

/// Links the app to the BuildLens glasses app (MicroLumin M6) over Wi-Fi.
///
/// The glasses app advertises `_buildlens-glass._tcp` and speaks newline-separated JSON:
/// `{"step": 4, "finished": false}`, plus `"replay": true` to show a step again and
/// `"open": true` while the instructions are open on the phone. This class finds it with Bonjour, connects, sends the
/// current step whenever it changes, and reports steps changed on the glasses (touchpad,
/// ring, swipe). Phone and glasses must be on the same Wi-Fi (join the glasses to it in MLDemo).
@MainActor
final class GlassesLink {
    var onConnectionChange: ((Bool) -> Void)?
    /// True while the instructions are on screen on the phone. Every message then carries
    /// `"open": true`, which makes the glasses bring their own screen up if it isn't.
    var instructionsOpen = false

    /// Step, finished, replay.
    var onRemoteStep: ((Int, Bool, Bool) -> Void)?
    /// The glasses' greeting when the link comes up: the step they are on, and whether finished.
    var onHello: ((Int, Bool) -> Void)?
    /// The glasses are scanning for the phone's code (`"scan": true`): show the Table marker.
    var onScanRequest: (() -> Void)?
    /// The glasses have the set's box done (they saw it, or the phone's code after it).
    var onBoxScanned: (() -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var last: (step: Int, finished: Bool)?
    private var retryScheduled = false
    /// The glasses have greeted us on this connection. Only then are they reported as linked:
    /// through `adb forward` a connection opens (and closes again) even when nothing on the
    /// glasses is listening.
    private var greeted = false

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_buildlens-glass._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.connectIfNeeded(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
        #if os(iOS)
        startBluetooth()
        #endif
    }

    /// Remembers the step the glasses are already on (they just told us), without sending it
    /// back to them. It is what they get if the link drops and comes back.
    func note(step: Int, finished: Bool) {
        last = (step, finished)
    }

    /// `replay`: show the same step again from the start (the glasses' double click, or the
    /// phone's replay button).
    /// `view`: show the step from one of the four sides (the phone was turned by hand).
    /// `milestone`: the step is done and the "good job" moment is on; the next step follows.
    /// The phone's settings, for the glasses: fade the pieces already built, the voice.
    func sendSettings(fade: Bool, voice: String, aloud: Bool) {
        write("{\"fade\":\(fade),\"voice\":\"\(voice)\",\"aloud\":\(aloud)}\n")
    }

    /// The model's turn and zoom here, for the glasses to show the same.
    func sendView(spin: Double, zoom: Double?, tilt: Double?) {
        var line = String(format: "{\"spin\":%.1f", spin)
        if let zoom { line += String(format: ",\"zoom\":%.3f", zoom) }
        if let tilt { line += String(format: ",\"tilt\":%.1f", tilt) }
        write(line + "}\n")
    }

    /// A setting was changed on the glasses' menu: (fade, voice prefix, read aloud).
    var onSettings: ((Bool, String, Bool) -> Void)?

    /// The glasses have scanned the tag and placed the build.
    var onPlaced: (() -> Void)?

    /// The model was turned or zoomed on the glasses.
    var onRemoteView: ((Double, Double?, Double?) -> Void)?

    /// The set's box was scanned here: the glasses need not scan it themselves.
    /// The phone closed its code: the glasses build without scanning it.
    func sendScanSkipped() {
        write("{\"noscan\":true}\n")
    }

    func sendBoxScanned() {
        write("{\"box\":true}\n")
    }

    func send(step: Int, finished: Bool, replay: Bool = false, view: Int? = nil, milestone: Bool = false) {
        last = (step, finished)
        var line = "{\"step\":\(step),\"finished\":\(finished)"
        if replay { line += ",\"replay\":true" }
        if let view { line += ",\"view\":\(view)" }
        if milestone { line += ",\"milestone\":true" }
        if instructionsOpen { line += ",\"open\":true" }
        write(line + "}\n")
    }

    /// One line to the glasses: over Wi-Fi or USB when that link is up, else over Bluetooth.
    private func write(_ line: String) {
        if let connection, connection.state == .ready, greeted {
            connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
            return
        }
        #if os(iOS)
        if ble.ready { ble.send(Data(line.utf8)) }
        #endif
    }

    #if os(iOS)
    /// The glasses over Bluetooth, with no Wi-Fi or Mac (GlassesBLE).
    private let ble = GlassesBLE()
    private var bleBuffer = Data()
    private var bleGreeted = false

    private func startBluetooth() {
        ble.onData = { [weak self] data in
            guard let self else { return }
            self.bleBuffer.append(data)
            if self.bleBuffer.count > 256 * 1024 { self.bleBuffer.removeAll() }
            self.drainLines(&self.bleBuffer, overBluetooth: true)
        }
        ble.onReady = { [weak self] ready in
            guard let self else { return }
            if ready {
                // Opening BuildLens on the phone brings it up on the glasses too.
                self.ble.send(Data("{\"wake\":true}\n".utf8))
                if self.instructionsOpen, let last = self.last { self.send(step: last.step, finished: last.finished) }
            } else {
                self.bleBuffer.removeAll()
                if self.bleGreeted { self.bleGreeted = false; self.linkChanged() }
            }
        }
        ble.start()
    }
    #endif

    /// Linked by any route: reported once when the first comes up and once when the last goes.
    private var reportedLinked = false
    private func linkChanged() {
        #if os(iOS)
        let now = greeted || bleGreeted
        #else
        let now = greeted
        #endif
        guard now != reportedLinked else { return }
        reportedLinked = now
        onConnectionChange?(now)
    }

    #if os(macOS)
    private var usbTask: Task<Void, Never>?

    /// The Mac: the glasses plugged into its USB cable, reached through `adb forward` on the
    /// link's own port. No Wi-Fi needed; the Mac passes steps on to the phone (PeerSync).
    func startUSB() {
        guard usbTask == nil else { return }
        usbTask = Task { [weak self] in
            while !Task.isCancelled {
                if let self, self.connection == nil,
                   await Task.detached(operation: { GlassesFeed.forward(port: 52733) }).value {
                    self.connect(to: .hostPort(host: "127.0.0.1", port: 52733))
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }
    #endif

    private func connectIfNeeded(_ results: Set<NWBrowser.Result>) {
        guard connection == nil, let result = results.first else { return }
        connect(to: result.endpoint)
    }

    private func connect(to endpoint: NWEndpoint) {
        guard connection == nil else { return }
        let connection = NWConnection(to: endpoint, using: .tcp)
        self.connection = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        connection.start(queue: .main)
        receive()
    }

    private func stateChanged(_ state: NWConnection.State) {
        switch state {
        case .ready:
            // With the instructions open the phone leads: the glasses get our step. Otherwise
            // we wait for their greeting and keep our place in line with theirs.
            if instructionsOpen, let last { send(step: last.step, finished: last.finished) }
        case .failed, .cancelled, .waiting:
            // .waiting: the glasses were found but are not answering (switched off, restarting).
            // Left alone it would sit there until the network changed; drop it and look again.
            dropConnection()
        default:
            break
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty {
                    self.buffer.append(data)
                    self.drainLines(&self.buffer, overBluetooth: false)
                }
                if isComplete || error != nil {
                    self.dropConnection()
                } else {
                    self.receive()
                }
            }
        }
    }

    private struct Message: Decodable {
        let step: Int
        let finished: Bool?
        let replay: Bool?
        let hello: Bool?
        let scan: Bool?
        let box: Bool?
        let spin: Double?
        let zoom: Double?
        let tilt: Double?
        let placed: Bool?
        let fade: Bool?
        let voice: String?
        let aloud: Bool?
    }

    private func drainLines(_ buffer: inout Data, overBluetooth: Bool) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if let message = try? JSONDecoder().decode(Message.self, from: Data(line)) {
                #if os(iOS)
                if overBluetooth { if !bleGreeted { bleGreeted = true; linkChanged() } }
                else if !greeted { greeted = true; linkChanged() }
                #else
                if !greeted { greeted = true; linkChanged() }
                #endif
                if let spin = message.spin {
                    onRemoteView?(spin, message.zoom, message.tilt)
                    continue
                }
                if message.placed == true { onPlaced?() }
                if let fade = message.fade {
                    onSettings?(fade, message.voice ?? "", message.aloud ?? false)
                    continue
                }
                if message.box == true { onBoxScanned?() }
                if message.hello == true {
                    onHello?(message.step, message.finished ?? false)
                } else {
                    onRemoteStep?(message.step, message.finished ?? false, message.replay ?? false)
                }
                // After the step: the request rides on a step line, and a step alone means "building".
                if message.scan == true { onScanRequest?() }
            }
        }
    }

    private func dropConnection() {
        guard connection != nil else { return }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        if greeted { greeted = false; linkChanged() }
        // Try again shortly (the glasses app may have restarted).
        guard !retryScheduled else { return }
        retryScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self else { return }
            self.retryScheduled = false
            if let results = self.browser?.browseResults { self.connectIfNeeded(results) }
        }
    }
}
