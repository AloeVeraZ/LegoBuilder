#if os(iOS)
import CoreBluetooth
import Foundation

/// The phone's Bluetooth Low Energy link to the glasses (glasses/.../BleLink.java), for when
/// there is no Wi-Fi and no Mac: no pairing, the glasses are found by their service. Carries
/// the same lines as the TCP link (one JSON object per line), cut to the link's packet size.
@MainActor
final class GlassesBLE: NSObject {
    static let service = CBUUID(string: "6b1d0001-6c6f-4a7e-9b5a-42756c644c6e")
    static let rx = CBUUID(string: "6b1d0002-6c6f-4a7e-9b5a-42756c644c6e")   // phone -> glasses
    static let tx = CBUUID(string: "6b1d0003-6c6f-4a7e-9b5a-42756c644c6e")   // glasses -> phone

    /// Bytes from the glasses (pieces of lines).
    var onData: ((Data) -> Void)?
    /// Linked (subscribed and ready to write) or not.
    var onReady: ((Bool) -> Void)?

    private var central: CBCentralManager?
    private var glasses: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private(set) var ready = false {
        didSet { if ready != oldValue { onReady?(ready) } }
    }
    private var queue: [Data] = []

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    /// One line (with its newline) to the glasses, in packets they can take.
    func send(_ line: Data) {
        guard ready, let glasses, let rxCharacteristic else { return }
        let size = max(20, glasses.maximumWriteValueLength(for: .withoutResponse))
        var at = 0
        while at < line.count {
            queue.append(line.subdata(in: at ..< min(at + size, line.count)))
            at += size
        }
        // A link that has fallen far behind only keeps what is new.
        if queue.count > 400 { queue.removeFirst(queue.count - 400) }
        pump(glasses, rxCharacteristic)
    }

    private func pump(_ glasses: CBPeripheral, _ rx: CBCharacteristic) {
        while !queue.isEmpty, glasses.canSendWriteWithoutResponse {
            glasses.writeValue(queue.removeFirst(), for: rx, type: .withoutResponse)
        }
    }

    private func scan() {
        guard let central, central.state == .poweredOn, glasses == nil else { return }
        central.scanForPeripherals(withServices: [Self.service], options: nil)
    }

    private func lost() {
        ready = false
        glasses = nil
        rxCharacteristic = nil
        queue.removeAll()
        // Look again in a moment (the glasses may be restarting or out of range).
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.scan()
        }
    }
}

extension GlassesBLE: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn { scan() } else if glasses != nil { lost() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard glasses == nil else { return }
            glasses = peripheral
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.delegate = self
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { lost() }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { lost() }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.service }) else { return }
            peripheral.discoverCharacteristics([Self.rx, Self.tx], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == Self.rx { rxCharacteristic = c }
                if c.uuid == Self.tx { peripheral.setNotifyValue(true, for: c) }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if characteristic.uuid == Self.tx, characteristic.isNotifying, rxCharacteristic != nil { ready = true }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.tx, let value = characteristic.value else { return }
        MainActor.assumeIsolated { onData?(value) }
    }

    nonisolated func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            if let rxCharacteristic { pump(peripheral, rxCharacteristic) }
        }
    }
}
#endif
