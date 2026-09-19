import Foundation
import MultipeerConnectivity
import CoreMedia

/// A separate encrypted MCSession keeps video out of the reliable control queue.
/// A bounded flight window covers normal Wi-Fi RTT without stop-and-wait judder.
final class RemotePreviewChannel: NSObject {
    let name = "FacePullVideo-" + String(CameraLibrary.stableSecret("peerID").prefix(8))
    var onDemand: ((Bool) -> Void)?
    var onKeyframe: (() -> Void)?
    var onPacket: ((PreviewPacket) -> Bool)?
    var onStatus: ((String) -> Void)?
    var onReset: (() -> Void)?
    private let host: Bool
    private let queue = DispatchQueue(label: "facepull.preview.transport", qos: .userInitiated)
    private let gate = NSLock()
    private var accepting = false
    private var window = PreviewSendWindow()
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var peer: MCPeerID?
    private var token = ""
    private var target = ""
    private var sequence: UInt32 = 0
    private var watchdog: DispatchSourceTimer?
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
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 0.05, repeating: 0.05, leeway: .milliseconds(5))
                timer.setEventHandler { [weak self] in self?.checkDeadline() }
                self.watchdog = timer; timer.resume()
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
        gate.lock(); generation &+= 1; accepting = false; window = PreviewSendWindow(); gate.unlock()
        watchdog?.cancel(); watchdog = nil
        advertiser?.stopAdvertisingPeer(); advertiser = nil
        browser?.stopBrowsingForPeers(); browser = nil
        session?.delegate = nil; session?.disconnect(); session = nil
        peer = nil
        if host { onDemand?(false) }
    }

    func offer(_ frame: H264Encoder.Frame) {
        gate.lock()
        guard accepting else { gate.unlock(); return }
        let now = ProcessInfo.processInfo.systemUptime
        let age = Int32(bitPattern: LiveStreamClock.ticks(CMClockGetTime(CMClockGetHostTimeClock()).seconds, rate: 90_000) &- frame.timestamp)
        if age > 13_500 { window.requireKeyframe(); gate.unlock(); return }
        let sequence = self.sequence &+ 1
        guard window.admit(sequence: sequence, keyframe: frame.isKeyframe, now: now) else {
            gate.unlock(); return
        }
        self.sequence = sequence
        let generation = self.generation
        gate.unlock()
        queue.async {
            guard self.generation == generation else { return }
            guard let session = self.session, let peer = self.peer else { self.release(sequence, needsKeyframe: true); return }
            guard let data = PreviewPacket(sequence: sequence, timestamp: frame.timestamp,
                keyframe: frame.isKeyframe, units: frame.nalUnits).encoded() else {
                self.release(sequence, needsKeyframe: true); return
            }
            do {
                try session.send(data, toPeers: [peer], with: .reliable)
            } catch { self.release(sequence, needsKeyframe: true); session.disconnect() }
        }
    }

    private func release(_ sequence: UInt32, needsKeyframe: Bool) {
        gate.lock()
        let sentAt = window.pending[sequence]
        let valid = window.acknowledge(sequence, needsKeyframe: needsKeyframe)
        let recover = window.needsKeyframe
        gate.unlock()
        guard valid else { return }
        if let sentAt { StreamDiagnostics.sample("Preview round trip", milliseconds: (ProcessInfo.processInfo.systemUptime - sentAt) * 1000) }
        if recover { requestRecovery() }
    }

    private func requestRecovery() {
        if Date().timeIntervalSince(lastKeyframeRequest) >= 0.25 {
            lastKeyframeRequest = Date(); onKeyframe?()
        }
    }

    private func checkDeadline() {
        guard host else { return }
        gate.lock()
        let expired = window.expired(now: ProcessInfo.processInfo.systemUptime)
        let recover = accepting && window.needsKeyframe
        if expired { generation &+= 1; accepting = false; window = PreviewSendWindow() }
        gate.unlock()
        if expired {
            // MCSession cannot selectively retract reliable packets already sent.
            // Drop the session rather than let a recovered link replay its backlog.
            session?.disconnect(); onDemand?(false)
        } else if recover { requestRecovery() }
    }
}

extension RemotePreviewChannel: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        queue.async {
            guard self.session === session else { return }
            switch state {
            case .connected:
                self.onReset?()
                self.peer = peerID
                self.gate.lock(); self.accepting = self.host; self.window = PreviewSendWindow(); self.gate.unlock()
                if self.host { self.onDemand?(true); self.onKeyframe?() }
                else { self.onStatus?("Live Preview") }
            case .notConnected:
                self.onReset?()
                self.gate.lock(); self.generation &+= 1; self.accepting = false; self.window = PreviewSendWindow(); self.gate.unlock()
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
                guard data.count == 8, data[0] == 0x46, data[1] == 0x41, data[2] == 1 else { return }
                self.release(data.readBE(at: 4), needsKeyframe: data[3] != 0)
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
