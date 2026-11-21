import Foundation
#if os(iOS)
import AVFoundation
import UIKit
#endif

/// While the phone is linked to the Mac or the glasses it is one half of the same thing, so
/// it keeps going: the screen does not dim and lock while it is in use (turning, zooming,
/// building), and if it is sent to the background (home button) it keeps running, so the link
/// and the shared view carry on. iOS stops background apps within about 30 seconds unless
/// they play audio, so silence is played while linked and in the background. Fine for a
/// device of our own; the App Store would not accept it.
@MainActor
final class KeepAwake {
    var linked = false { didSet { if linked != oldValue { update() } } }
    #if os(iOS)
    private var player: AVAudioPlayer?
    private var inBackground = false
    private var lastTouch = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inBackground = true; self?.update() }
        })
        observers.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.inBackground = false; self?.update() }
        })
    }

    /// Something was turned or zoomed: the screen stays on.
    func touch() {
        lastTouch = Date()
        update()
    }

    private func update() {
        // Screen on while linked (the phone is part of the build).
        UIApplication.shared.isIdleTimerDisabled = linked || Date().timeIntervalSince(lastTouch) < 300
        // Running in the background while linked.
        if linked && inBackground { playSilence() } else { stopSilence() }
    }

    private func playSilence() {
        guard player == nil else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(data: Self.silentWAV())
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            self.player = player
        } catch {
            player = nil
        }
    }

    private func stopSilence() {
        player?.stop()
        player = nil
    }

    /// One second of silence as a WAV file (16-bit mono, 8 kHz).
    private static func silentWAV() -> Data {
        let rate: UInt32 = 8000, samples = rate
        var data = Data()
        func add<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); add(UInt32(36 + samples * 2).littleEndian)
        data.append(contentsOf: Array("WAVEfmt ".utf8)); add(UInt32(16).littleEndian); add(UInt16(1).littleEndian)
        add(UInt16(1).littleEndian); add(rate.littleEndian); add((rate * 2).littleEndian); add(UInt16(2).littleEndian)
        add(UInt16(16).littleEndian)
        data.append(contentsOf: Array("data".utf8)); add((samples * 2).littleEndian)
        data.append(Data(count: Int(samples * 2)))
        return data
    }
    #else
    func touch() {}
    private func update() {}
    #endif
}
