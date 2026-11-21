import Foundation
import Network
import os

let linkLog = Logger(subsystem: "com.aloeveraz.buildlens", category: "link")

/// The phone and the Mac over the USB cable, so they stay together with no Wi-Fi. The phone
/// listens on `port`; the Mac reaches it through macOS's own service for plugged-in iPhones
/// (usbmuxd, /var/run/usbmuxd: the same one Xcode and Finder use), which carries a TCP
/// connection over the cable. Both ends send PeerSync's messages, one JSON object a line.
@MainActor
final class USBLink {
    nonisolated static let port: UInt16 = 52735

    /// One message line arrived (without its newline).
    var onLine: ((Data) -> Void)?
    var onConnectionChange: ((Bool) -> Void)?
    private(set) var connected = false {
        didSet { if connected != oldValue { onConnectionChange?(connected) } }
    }

    #if os(iOS)
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: Self.port),
              let listener = try? NWListener(using: .tcp, on: port) else { return }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            Task { @MainActor in
                guard let self, let connection else { return }
                switch state {
                case .ready:
                    self.connected = true
                    // Straight away, so the Mac knows the way back works too.
                    var hello = Data("{\"hello\":true}".utf8)
                    hello.append(0x0A)
                    connection.send(content: hello, completion: .contentProcessed { _ in })
                case .failed, .cancelled: self.drop(connection)
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                buffer = self.lines(in: buffer)
                if complete || error != nil { self.drop(connection) } else { self.receive(on: connection, buffer: buffer) }
            }
        }
    }

    private func drop(_ connection: NWConnection) {
        connection.cancel()
        connections.removeAll { $0 === connection }
        connected = !connections.isEmpty
    }

    func send(_ data: Data) {
        var line = data
        line.append(0x0A)
        for connection in connections where connection.state == .ready {
            connection.send(content: line, completion: .contentProcessed { _ in })
        }
    }
    #else
    private var loop: Task<Void, Never>?
    nonisolated(unsafe) private var socket: Int32 = -1
    private let writer = DispatchQueue(label: "buildlens.usb.write")

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if !self.connected {
                    let fd = await Task.detached { Self.connectToPhone() }.value
                    if let fd {
                        self.socket = fd
                        self.connected = true
                        await self.read(fd)
                        Darwin.close(fd)
                        self.socket = -1
                        self.connected = false
                    }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Reads lines until the phone goes (blocking reads, off the main thread).
    private func read(_ fd: Int32) async {
        let stream = AsyncStream<Data> { continuation in
            Thread.detachNewThread {
                var buffer = [UInt8](repeating: 0, count: 65536)
                while true {
                    let n = Darwin.read(fd, &buffer, buffer.count)
                    if n <= 0 { break }
                    continuation.yield(Data(buffer[0 ..< n]))
                }
                continuation.finish()
            }
        }
        var pending = Data()
        for await chunk in stream {
            pending.append(chunk)
            pending = lines(in: pending)
        }
    }

    func send(_ data: Data) {
        let fd = socket
        guard fd >= 0 else { return }
        var line = data
        line.append(0x0A)
        writer.async {
            line.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let n = Darwin.write(fd, raw.baseAddress! + sent, raw.count - sent)
                    if n <= 0 { return }
                    sent += n
                }
            }
        }
    }

    // MARK: usbmuxd

    /// A socket carried over the cable to the plugged-in iPhone's `port`, or nil.
    private nonisolated static func connectToPhone() -> Int32? {
        guard let list = muxSocket() else { return nil }
        defer { Darwin.close(list) }
        guard sendPlist(list, ["MessageType": "ListDevices", "ClientVersionString": "BuildLens", "ProgName": "BuildLens"]),
              let reply = readPlist(list), let devices = reply["DeviceList"] as? [[String: Any]] else { return nil }
        let usb = devices.compactMap { device -> Int? in
            guard let properties = device["Properties"] as? [String: Any],
                  properties["ConnectionType"] as? String == "USB" else { return nil }
            return (device["DeviceID"] as? Int) ?? (properties["DeviceID"] as? Int)
        }
        for id in usb {
            guard let fd = muxSocket() else { continue }
            // The port goes in network byte order.
            let message: [String: Any] = ["MessageType": "Connect", "DeviceID": id, "PortNumber": Int(port.byteSwapped),
                                          "ClientVersionString": "BuildLens", "ProgName": "BuildLens"]
            if sendPlist(fd, message), let result = readPlist(fd), (result["Number"] as? Int) == 0 { return fd }
            Darwin.close(fd)
        }
        return nil
    }

    private nonisolated static func muxSocket() -> Int32? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = "/var/run/usbmuxd"
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (i, byte) in path.utf8.enumerated() where i < raw.count - 1 { raw[i] = byte }
        }
        let ok = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if ok != 0 { Darwin.close(fd); return nil }
        return fd
    }

    /// One usbmuxd message: a 16-byte header (length, version 1, type 8 = plist, tag), then XML.
    private nonisolated static func sendPlist(_ fd: Int32, _ dictionary: [String: Any]) -> Bool {
        guard let body = try? PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0) else { return false }
        var packet = Data()
        for value in [UInt32(16 + body.count), 1, 8, 1] { withUnsafeBytes(of: value.littleEndian) { packet.append(contentsOf: $0) } }
        packet.append(body)
        return packet.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) == $0.count }
    }

    private nonisolated static func readPlist(_ fd: Int32) -> [String: Any]? {
        guard let header = readExactly(fd, 16) else { return nil }
        let length = Int(header.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian)
        guard length > 16, length < 1 << 20, let body = readExactly(fd, length - 16) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: body, options: [], format: nil)) as? [String: Any]
    }

    private nonisolated static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var out = Data(count: count)
        var got = 0
        while got < count {
            let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            if n <= 0 { return nil }
            got += n
        }
        return out
    }
    #endif

    /// Hands each whole line on; returns what is left of an unfinished one.
    private func lines(in buffer: Data) -> Data {
        var rest = buffer
        while let newline = rest.firstIndex(of: 0x0A) {
            let line = rest[rest.startIndex ..< newline]
            rest = Data(rest[rest.index(after: newline)...])
            if !line.isEmpty {
                linkLog.info("usb in: \(String(decoding: line, as: UTF8.self), privacy: .public)")
                onLine?(Data(line))
            }
        }
        return rest
    }
}
