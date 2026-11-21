import Foundation
import Network

/// Links the app to the BuildLens glasses app (MicroLumin M6) over Wi-Fi.
///
/// The glasses app advertises `_buildlens-glass._tcp` and speaks newline-separated JSON:
/// `{"step": 4, "finished": false}`. This class finds it with Bonjour, connects, sends the
/// current step whenever it changes, and reports steps changed on the glasses (touchpad,
/// ring, swipe). Phone and glasses must be on the same Wi-Fi (join the glasses to it in MLDemo).
@MainActor
final class GlassesLink {
    var onConnectionChange: ((Bool) -> Void)?
    var onRemoteStep: ((Int, Bool) -> Void)?

    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var buffer = Data()
    private var last: (step: Int, finished: Bool)?
    private var retryScheduled = false

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_buildlens-glass._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.connectIfNeeded(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func send(step: Int, finished: Bool) {
        last = (step, finished)
        guard let connection, connection.state == .ready else { return }
        let line = "{\"step\":\(step),\"finished\":\(finished)}\n"
        connection.send(content: Data(line.utf8), completion: .contentProcessed { _ in })
    }

    private func connectIfNeeded(_ results: Set<NWBrowser.Result>) {
        guard connection == nil, let result = results.first else { return }
        let connection = NWConnection(to: result.endpoint, using: .tcp)
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
            onConnectionChange?(true)
            if let last { send(step: last.step, finished: last.finished) }
        case .failed, .cancelled:
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
                    self.drainLines()
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
    }

    private func drainLines() {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if let message = try? JSONDecoder().decode(Message.self, from: Data(line)) {
                onRemoteStep?(message.step, message.finished ?? false)
            }
        }
    }

    private func dropConnection() {
        guard connection != nil else { return }
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        onConnectionChange?(false)
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
