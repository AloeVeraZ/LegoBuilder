#if os(macOS)
import Foundation
import ImageIO
import Network
import Observation
import simd

/// What the glasses' camera sees and where the glasses found the phone's marker, while the
/// glasses are plugged into this Mac with their USB cable. The glasses app serves it on
/// its own port (glasses/.../LiveFeed.java); `adb forward` carries it over the cable.
/// The ghost drawn on it uses the glasses' own tracking, so it shows what the glasses think.
@MainActor
@Observable
final class GlassesFeed {
    nonisolated static let port: UInt16 = 52734

    /// True while pictures are arriving from plugged-in glasses.
    private(set) var plugged = false
    private(set) var image: CGImage?
    /// Camera from marker, as MarkerTracker's pose (nil while the marker is not seen).
    private(set) var pose: simd_float4x4?
    private(set) var imageSize = CGSize(width: 640, height: 480)
    /// fx, fy, cx, cy in pixels, with the picture spanning 0...width.
    private(set) var lens = SIMD4<Float>(586, 586, 320, 240)
    /// The step the glasses are on, and whether they show the finish.
    private(set) var step = 0
    private(set) var finished = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var lastPicture = Date.distantPast

    func start() {
        guard task == nil else { return }
        task = Task { await run() }
    }

    func stop() {
        task?.cancel()
        task = nil
        clear()
    }

    private func clear() {
        plugged = false
        image = nil
        pose = nil
    }

    private func run() async {
        // Notices glasses that stop sending (their display went to sleep) while still connected.
        let watchdog = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if self.plugged, Date().timeIntervalSince(self.lastPicture) > 2 { self.clear() }
            }
        }
        defer { watchdog.cancel() }
        while !Task.isCancelled {
            if await Task.detached(operation: { Self.forward(port: Self.port) }).value {
                await read()
            }
            clear()
            try? await Task.sleep(for: .seconds(2))
        }
    }

    // MARK: the cable

    private nonisolated static let adbPaths = [
        "/opt/homebrew/bin/adb", "/usr/local/bin/adb",
        NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
        "/opt/homebrew/share/android-commandlinetools/platform-tools/adb",
    ]

    /// Finds plugged-in glasses (any adb device that is not an emulator) and carries `port`
    /// over the cable, so 127.0.0.1:port on this Mac reaches it on the glasses. False when
    /// there are none. Also used for the step link (GlassesLink.startUSB).
    nonisolated static func forward(port: UInt16) -> Bool {
        guard let adb = adbPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return false }
        guard let list = run(adb, ["devices"]) else { return false }
        let serial = list.split(separator: "\n").dropFirst().compactMap { line -> String? in
            let parts = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            guard parts.count >= 2, parts[1] == "device", !parts[0].hasPrefix("emulator-") else { return nil }
            return String(parts[0])
        }.first
        guard let serial else { return false }
        return run(adb, ["-s", serial, "forward", "tcp:\(port)", "tcp:\(port)"]) != nil
    }

    private nonisolated static func run(_ tool: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: the pictures

    private struct Header: Decodable {
        let w: Int, h: Int
        let fx: Float, fy: Float, cx: Float, cy: Float
        let step: Int
        let finished: Bool
        let pose: [Float]?
        let jpeg: Int
    }

    /// Reads pictures until the connection ends or this is cancelled.
    private func read() async {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!, using: .tcp)
        connection.start(queue: .global(qos: .userInitiated))
        defer { connection.cancel() }
        var buffer = Data()
        var header: Header?
        while !Task.isCancelled {
            guard let chunk = await Self.receive(on: connection) else { return }
            buffer.append(chunk)
            while true {
                if header == nil {
                    guard let end = buffer.firstIndex(of: UInt8(ascii: "\n")) else { break }
                    let line = buffer[buffer.startIndex ..< end]
                    buffer = Data(buffer[buffer.index(after: end)...])
                    guard let parsed = try? JSONDecoder().decode(Header.self, from: line) else { return }
                    header = parsed
                }
                guard let head = header, buffer.count >= head.jpeg else { break }
                let jpeg = Data(buffer.prefix(head.jpeg))
                buffer = Data(buffer.dropFirst(head.jpeg))
                header = nil
                took(head, jpeg)
            }
        }
    }

    private nonisolated static func receive(on connection: NWConnection) async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { data, _, complete, error in
                    if let data, !data.isEmpty, error == nil { done.resume(returning: data) }
                    else if complete || error != nil { done.resume(returning: nil) }
                    else { done.resume(returning: Data()) }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    private func took(_ head: Header, _ jpeg: Data) {
        guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
              let picture = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return }
        image = picture
        imageSize = CGSize(width: head.w, height: head.h)
        // The glasses count from pixel centres; here the picture spans 0...width.
        lens = SIMD4(head.fx, head.fy, head.cx + 0.5, head.cy + 0.5)
        if let p = head.pose, p.count == 16 {
            pose = simd_float4x4(columns: (
                SIMD4(p[0], p[1], p[2], p[3]), SIMD4(p[4], p[5], p[6], p[7]),
                SIMD4(p[8], p[9], p[10], p[11]), SIMD4(p[12], p[13], p[14], p[15])
            ))
        } else {
            pose = nil
        }
        step = head.step
        finished = head.finished
        lastPicture = Date()
        plugged = true
    }
}
#endif
