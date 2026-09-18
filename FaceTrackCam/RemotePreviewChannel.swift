import Foundation
import MultipeerConnectivity

/// A separate encrypted MCSession keeps video out of the reliable control queue.
/// One acknowledged frame is the entire transport window; slow peers lose frames.
final class RemotePreviewChannel: NSObject {
    let name = "FacePullVideo-" + String(CameraLibrary.stableSecret("peerID").prefix(8))
    var onDemand: ((Bool) -> Void)?
    var onKeyframe: (() -> Void)?
    var onPacket: ((PreviewPacket) -> Bool)?
    var onStatus: ((String) -> Void)?
    private let host: Bool
    private let queue = DispatchQueue(label: "facepull.preview.transport", qos: .userInitiated)
    private let gate = NSLock()
    private var accepting = false
    private var busy = false
    private var dropped = false
    private var needsKeyframe = true
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peer: MCPeerID?
    private var token = ""
    private var target = ""
    private var sequence: UInt32 = 0
    private var outstanding: UInt32?
    private var generation = 0
    private var lastKeyframeRequest = Date.distantPast

    init(host: Bool) { self.host = host; super.init() }

    func start(token: String, target: String = "") {
        queue.async {
            if self.session != nil, self.token == token, self.target == target { return }
            self.stopInternal()
            self.token = token; self.target = target
            let id = MCPeerID(displayName: self.name)
            let session = MCSession(peer: id, securityIdentity: nil, encryptionPreference: .required)
            session.delegate = self; self.session = session
            if self.host {
                let advertiser = MCNearbyServiceAdvertiser(peer: id, discoveryInfo: nil, serviceType: "facepull-video")
                advertiser.delegate = self; self.advertiser = advertiser
                advertiser.startAdvertisingPeer()
            } else {
                let browser = MCNearbyServiceBrowser(peer: id, serviceType: "facepull-video")
                browser.delegate = self; self.browser = browser
                browser.startBrowsingForPeers()
                self.onStatus?("Connecting preview…")
            }
        }
    }

    func stop() { queue.async { self.stopInternal() } }

    private func stopInternal() {
        gate.lock(); generation &+= 1; accepting = false; busy = false; dropped = false; needsKeyframe = true; gate.unlock()
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session?.delegate = nil; session?.disconnect(); session = nil
        peer = nil; outstanding = nil
        if host { onDemand?(false) }
    }

    func offer(_ frame: H264Encoder.Frame) {
        gate.lock()
        guard accepting else { gate.unlock(); return }
        guard !busy else { dropped = true; gate.unlock(); return }
        guard !needsKeyframe || frame.isKeyframe else { gate.unlock(); return }
        busy = true; needsKeyframe = false
        let generation = self.generation
        gate.unlock()
        queue.async {
            guard self.generation == generation else { return }
            guard let session = self.session, let peer = self.peer else { self.release(needsKeyframe: true); return }
            self.sequence &+= 1
            let sequence = self.sequence
            guard let data = PreviewPacket(sequence: sequence, timestamp: frame.timestamp,
                keyframe: frame.isKeyframe, units: frame.nalUnits).encoded() else {
                self.release(needsKeyframe: true); return
            }
            do {
                try session.send(data, toPeers: [peer], with: .reliable)
                self.outstanding = sequence
                let generation = self.generation
                self.queue.asyncAfter(deadline: .now() + 1) { [weak self, weak session] in
                    guard let self, self.generation == generation, self.outstanding == sequence else { return }
                    session?.disconnect() // discard any stale transport data, reconnect at an IDR
                    self.release(needsKeyframe: true)
                }
            } catch { self.release(needsKeyframe: true); session.disconnect() }
        }
    }

    private func release(needsKeyframe: Bool) {
        outstanding = nil
        gate.lock()
        self.needsKeyframe = self.needsKeyframe || needsKeyframe || dropped
        let recover = self.needsKeyframe
        busy = false; dropped = false
        gate.unlock()
        if recover && Date().timeIntervalSince(lastKeyframeRequest) >= 1 {
            lastKeyframeRequest = Date(); onKeyframe?()
        }
    }
}

extension RemotePreviewChannel: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async {
            guard self.session === session else { return }
            switch state {
            case .connected:
                self.peer = peerID
                self.gate.lock(); self.accepting = self.host; self.needsKeyframe = true; self.gate.unlock()
                if self.host { self.onDemand?(true); self.onKeyframe?() }
                else { self.onStatus?("Live Preview") }
            case .notConnected:
                self.gate.lock(); self.accepting = false; self.gate.unlock()
                self.release(needsKeyframe: true)
                if self.host { self.peer = nil; self.onDemand?(false) }
                else {
                    self.onStatus?("Reconnecting preview…")
                    let generation = self.generation
                    self.queue.asyncAfter(deadline: .now() + 0.5) {
                        guard self.generation == generation, self.session === session else { return }
                        self.browser?.invitePeer(peerID, to: session, withContext: Data(self.token.utf8), timeout: 5)
                    }
                }
            default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard data.count <= PreviewPacket.maximumBytes else { return }
        queue.async {
            guard self.session === session, self.peer == peerID else { return }
            if self.host {
                guard data.count == 8, data[0] == 0x46, data[1] == 0x41, data[2] == 1,
                      self.outstanding == data.readBE(at: 4) else { return }
                self.release(needsKeyframe: data[3] != 0)
            } else {
                guard let packet = PreviewPacket.decode(data) else { session.disconnect(); return }
                let accepted = self.onPacket?(packet) ?? false
                try? session.send(PreviewPacket.acknowledgement(packet.sequence, needsKeyframe: !accepted),
                                  toPeers: [peerID], with: .reliable)
            }
        }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension RemotePreviewChannel: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        queue.async {
            guard self.advertiser === advertiser, self.host, context == Data(self.token.utf8),
                  let session = self.session, session.connectedPeers.isEmpty else { invitationHandler(false, nil); return }
            invitationHandler(true, session)
        }
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        onStatus?("Preview unavailable: \(error.localizedDescription)")
    }
}

extension RemotePreviewChannel: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        queue.async {
            guard self.browser === browser, peerID.displayName == self.target, let session = self.session,
                  self.peer == nil else { return }
            self.peer = peerID
            browser.invitePeer(peerID, to: session, withContext: Data(self.token.utf8), timeout: 5)
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        onStatus?("Preview unavailable: \(error.localizedDescription)")
    }
}
