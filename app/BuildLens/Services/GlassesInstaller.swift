#if os(macOS)
import Foundation
import os

/// The Mac app carries the glasses app (BuildLensGlasses.apk, put in by app/install-mac.sh or
/// the release build) and puts it on any glasses plugged into this Mac: installed if they
/// don't have it, updated if theirs is older, then opened. Nothing to do on the glasses.
enum GlassesInstaller {
    private static let package = "com.buildlens.glasses"
    private static let lock = NSLock()
    /// Glasses (by serial) already checked since this Mac app started.
    nonisolated(unsafe) private static var checked = Set<String>()
    private static let log = Logger(subsystem: "com.aloeveraz.buildlens", category: "install")

    /// The glasses app inside this Mac app, and its version number (0 if there is none).
    private static var bundled: (apk: URL, version: Int)? {
        guard let apk = Bundle.main.url(forResource: "BuildLensGlasses", withExtension: "apk"),
              let text = try? String(contentsOf: apk.deletingLastPathComponent().appendingPathComponent("BuildLensGlasses.version"), encoding: .utf8),
              let version = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        return (apk, version)
    }

    /// Makes sure the glasses `serial` have this Mac app's glasses app. Once per glasses per
    /// launch; blocks while it installs (about 20 s), so call it off the main thread.
    static func ensure(adb: String, serial: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !checked.contains(serial), let bundled else { return }
        checked.insert(serial)
        let installed = installedVersion(adb: adb, serial: serial)
        guard installed < bundled.version else { return }
        log.info("glasses \(serial, privacy: .public): version \(installed) -> \(bundled.version), installing")
        var out = run(adb, ["-s", serial, "install", "-r", "-g", bundled.apk.path])
        if out.contains("INSTALL_FAILED_UPDATE_INCOMPATIBLE") {
            // Built on another computer (signed with another key): the old one has to go first.
            _ = run(adb, ["-s", serial, "uninstall", package])
            out = run(adb, ["-s", serial, "install", "-r", "-g", bundled.apk.path])
        }
        guard out.contains("Success") else {
            log.error("glasses install failed: \(out, privacy: .public)")
            checked.remove(serial)       // try again on the next plug-in check
            return
        }
        _ = run(adb, ["-s", serial, "shell", "am", "start", "-n", "\(package)/.MainActivity"])
        log.info("glasses \(serial, privacy: .public): BuildLens \(bundled.version) installed and opened")
    }

    /// The glasses app's version on the glasses; 0 if it is not there.
    private static func installedVersion(adb: String, serial: String) -> Int {
        let out = run(adb, ["-s", serial, "shell", "dumpsys", "package", package])
        guard let range = out.range(of: "versionCode=") else { return 0 }
        return Int(out[range.upperBound...].prefix(while: \.isNumber)) ?? 0
    }

    private static func run(_ tool: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = out
        do { try process.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
