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

    nonisolated(unsafe) private let me: MCPeerID
    nonisolated(unsafe) private let session: MCSession
    private let advertiser: MCNearbyServiceAdvertiser
    private let browser: MCNearbyServiceBrowser
    private var started = false

    private struct Message: Codable {
        let step: Int
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

    func start() {
        guard !started else { return }
        started = true
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func send(step: Int) {
        guard !session.connectedPeers.isEmpty, let data = try? JSONEncoder().encode(Message(step: step)) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension PeerSync: MCSessionDelegate, MCNearbyServiceAdvertiserDelegate, MCNearbyServiceBrowserDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let names = session.connectedPeers.map(\.displayName)
        Task { @MainActor in self.onPeersChanged?(names) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = try? JSONDecoder().decode(Message.self, from: data) else { return }
        let step = message.step
        Task { @MainActor in self.onRemoteStep?(step) }
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
