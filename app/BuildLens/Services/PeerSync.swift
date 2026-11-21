import Foundation
import MultipeerConnectivity
#if os(iOS)
import UIKit
#else
import SystemConfiguration
#endif

/// Keeps the current step in sync between nearby devices running the app (iPhone <-> Mac),
/// over Wi-Fi / Bluetooth with no setup. The same message will drive the glasses later.
@MainActor
final class PeerSync: NSObject {
    static let serviceType = "buildlens-sync"   // also listed in Info.plist (NSBonjourServices)

    var onPeersChanged: (([String]) -> Void)?
    var onRemoteStep: ((Int) -> Void)?
    /// Another device asks for the Table marker (the glasses are scanning; the Mac passes it on).
    var onScanRequest: (() -> Void)?
    /// Another device scanned the set's box.
    var onBoxScanned: (() -> Void)?
    /// The model was turned or zoomed on another device.
    var onRemoteView: ((Double, Double?, Double?) -> Void)?

    /// The glasses have placed the build (passed on by the Mac).
    var onPlaced: (() -> Void)?

    /// The phone's settings (passed on to the glasses by the Mac).
    var onSettings: ((Bool, String?, Bool) -> Void)?
    /// The Mac says whether glasses are plugged into it.
    var onGlassesThroughMac: ((Bool) -> Void)?

    func sendSettings(fade: Bool, voice: String, aloud: Bool) {
        send(Message(fade: fade, voice: voice, aloud: aloud))
    }

    func sendGlassesPresent(_ present: Bool) {
        send(Message(glasses: present))
    }

    func sendPlaced() {
        send(Message(placed: true))
    }

    func sendView(spin: Double, zoom: Double?, tilt: Double?) {
        send(Message(spin: spin, zoom: zoom, tilt: tilt))
    }

    nonisolated(unsafe) private let me: MCPeerID
    nonisolated(unsafe) private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var started = false

    private struct Message: Codable {
        var step: Int?
        var scan: Bool?
        var box: Bool?
        var spin: Double?
        var zoom: Double?
        var tilt: Double?
        var placed: Bool?
        var fade: Bool?
        var voice: String?
        var aloud: Bool?
        /// The Mac: whether glasses are plugged into it.
        var glasses: Bool?
    }

    /// `name` is how this device appears to the others; defaults to the device name.
    init(name customName: String? = nil) {
        #if os(iOS)
        let deviceName = UIDevice.current.name
        #else
        let deviceName = (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
        #endif
        let name = customName ?? deviceName
        let peer = MCPeerID(displayName: String(name.prefix(50)))
        me = peer
        session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
        advertiser = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: nil, serviceType: Self.serviceType)
        browser = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
        super.init()
        session.delegate = self
        advertiser.delegate = self
        browser.delegate = self
    }

    /// The phone and Mac over the USB cable as well (USBLink), for when there is no Wi-Fi.
    private let usb = USBLink()
    private var wirelessPeers: [String] = []

    func start() {
        guard !started else { return }
        started = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
        usb.onLine = { [weak self] data in self?.deliver(data) }
        usb.onConnectionChange = { [weak self] _ in self?.reportPeers() }
        usb.start()
    }

    /// Who is linked: wireless peers, and the other end of the cable.
    private func reportPeers() {
        #if os(iOS)
        let cable = "Mac (USB)"
        #else
        let cable = "iPhone (USB)"
        #endif
        onPeersChanged?(wirelessPeers + (usb.connected ? [cable] : []))
    }

    func send(step: Int) {
        send(Message(step: step))
    }

    /// Asks the others to put the Table marker up.
    func sendScanRequest() {
        send(Message(scan: true))
    }

    /// Tells the others the set's box was scanned here.
    func sendBoxScanned() {
        send(Message(box: true))
    }

    private func send(_ message: Message) {
        guard let data = try? JSONEncoder().encode(message) else { return }
        usb.send(data)
        guard !session.connectedPeers.isEmpty else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    /// A message from either link.
    nonisolated private func deliver(_ data: Data) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        if message.scan == true { Task { @MainActor in self.onScanRequest?() } }
        if message.box == true { Task { @MainActor in self.onBoxScanned?() } }
        if message.placed == true { Task { @MainActor in self.onPlaced?() } }
        if let fade = message.fade { let voice = message.voice, aloud = message.aloud ?? false; Task { @MainActor in self.onSettings?(fade, voice, aloud) } }
        if let glasses = message.glasses { Task { @MainActor in self.onGlassesThroughMac?(glasses) } }
        if let spin = message.spin { let zoom = message.zoom, tilt = message.tilt; Task { @MainActor in self.onRemoteView?(spin, zoom, tilt) } }
        if let step = message.step { Task { @MainActor in self.onRemoteStep?(step) } }
    }
}

extension PeerSync: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let names = session.connectedPeers.map(\.displayName)
        Task { @MainActor in
            self.wirelessPeers = names
            self.reportPeers()
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        deliver(data)
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        // Only one side sends the invitation so the two devices don't invite each other at once.
        guard !session.connectedPeers.contains(peerID), me.displayName <= peerID.displayName else { return }
        browser.invitePeer(peerID, to: session, withContext: nil, timeout: 20)
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
