import Foundation
import Combine
import CryptoKit
import MultipeerConnectivity
import Security

/// Encrypted local control channel. The camera and its remote share command/state
/// contracts; optional preview uses a separate encrypted session.
final class PeerControl: NSObject, ObservableObject {
    enum Role { case host, remote }

    @Published private(set) var discovered: [MCPeerID] = []
    @Published private(set) var connected = false
    @Published private(set) var authorized = false
    @Published private(set) var state: [String: Any] = [:]
    @Published var error: String?
    let pairingCode: String
    var onCommand: (([String: Any]) -> String?)?
    var onDisconnect: (() -> Void)?

    private let role: Role
    private let selfID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var invited = Set<String>()
    private var authorizedPeer: MCPeerID?
    private var activePeer: MCPeerID?
    var connectedHostName: String { activePeer?.displayName ?? "Not connected" }
    private var failedPairings: [String: Int] = [:]
    private var challenges: [String: String] = [:]
    private var pairNonces: [String: String] = [:]
    private var remoteNonce = ""
    private var verifiedHost = false
    private var enteredCode = ""
    private var revision = 0
    private var receivedRevision = 0
    private var lastState = Data()

    init(role: Role) {
        self.role = role
        let id = CameraLibrary.stableSecret("peerID")
        selfID = MCPeerID(displayName: "FacePull-\(id.prefix(8))")
        session = MCSession(peer: selfID, securityIdentity: nil, encryptionPreference: .required)
        pairingCode = String(format: "%06d", Int.random(in: 0...999999))
        super.init()
        session.delegate = self
        if role == .host {
            let advertiser = MCNearbyServiceAdvertiser(peer: selfID, discoveryInfo: nil, serviceType: "facepull")
            advertiser.delegate = self; advertiser.startAdvertisingPeer(); self.advertiser = advertiser
        } else {
            let browser = MCNearbyServiceBrowser(peer: selfID, serviceType: "facepull")
            browser.delegate = self; browser.startBrowsingForPeers(); self.browser = browser
        }
    }

    deinit {
        browser?.stopBrowsingForPeers()
        advertiser?.stopAdvertisingPeer()
        session.disconnect()
    }

    func connect(_ peer: MCPeerID) {
        guard role == .remote, !invited.contains(peer.displayName) else { return }
        if let activePeer, activePeer != peer { session.disconnect(); authorized = false; verifiedHost = false }
        activePeer = peer
        receivedRevision = 0
        invited.insert(peer.displayName)
        browser?.invitePeer(peer, to: session, withContext: nil, timeout: 20)
    }

    func pair(code: String) {
        guard role == .remote, connected else { return }
        enteredCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        send(["type": "pair", "code": enteredCode])
    }

    func command(_ action: String, value: Any? = nil) {
        guard role == .remote, authorized else { return }
        if let value, state[action] != nil {
            var snapshot = state
            if let raw = value as? String, let number = Double(raw),
               ["intensity", "exposure", "temperature"].contains(action) { snapshot[action] = number }
            else { snapshot[action] = value }
            state = snapshot
        }
        var message: [String: Any] = ["type": "command", "action": action]
        if let value { message["value"] = value }
        send(message)
    }

    func publish(_ snapshot: [String: Any]) {
        guard role == .host, authorized, let data = try? JSONSerialization.data(withJSONObject: snapshot, options: .sortedKeys),
              data != lastState,
              let authorizedPeer,
              session.connectedPeers.contains(authorizedPeer) else { return }
        let nextRevision = revision + 1
        guard send(["type": "state", "revision": nextRevision, "state": snapshot], to: authorizedPeer) else { return }
        revision = nextRevision
        lastState = data
    }

    @discardableResult
    private func send(_ message: [String: Any], to peer: MCPeerID? = nil) -> Bool {
        let targets = peer.map { [$0] } ?? (role == .remote ? activePeer.map { [$0] } ?? [] : session.connectedPeers)
        guard !targets.isEmpty,
              targets.allSatisfy(session.connectedPeers.contains),
              let data = try? JSONSerialization.data(withJSONObject: message) else { return false }
        do {
            try session.send(data, toPeers: targets, with: .reliable)
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    private func receive(_ message: [String: Any], from peer: MCPeerID) {
        guard session.connectedPeers.contains(peer),
              role == .host || activePeer == peer else { return }
        guard let type = message["type"] as? String else { return }
        switch (role, type) {
        case (.host, "hello"):
            guard let nonce = message["nonce"] as? String else { return }
            pairNonces[peer.displayName] = nonce
            guard let token = PeerSecret.load("host:\(peer.displayName)") else { return }
            let challenge = UUID().uuidString
            challenges[peer.displayName] = challenge
            send(["type": "challenge", "nonce": challenge,
                  "proof": Self.proof(token, text: "host:\(nonce)")], to: peer)
        case (.host, "proof"):
            guard let token = PeerSecret.load("host:\(peer.displayName)"),
                  let challenge = challenges.removeValue(forKey: peer.displayName),
                  let proof = message["proof"] as? String,
                  proof == Self.proof(token, text: "remote:\(challenge)") else { return }
            if authorizedPeer != peer { onDisconnect?() }
            authorizedPeer = peer; authorized = true; lastState = Data()
        case (.host, "pair"):
            guard failedPairings[peer.displayName, default: 0] < 5 else { return }
            guard (message["code"] as? String) == pairingCode else {
                failedPairings[peer.displayName, default: 0] += 1
                send(["type": "error", "message": "Pairing code is incorrect."], to: peer); return
            }
            failedPairings[peer.displayName] = 0
            let token = UUID().uuidString + UUID().uuidString
            PeerSecret.save(token, key: "host:\(peer.displayName)")
            if authorizedPeer != peer { onDisconnect?() }
            authorizedPeer = peer; authorized = true; lastState = Data()
            let nonce = pairNonces[peer.displayName] ?? ""
            send(["type": "paired", "token": token,
                  "proof": Self.proof(pairingCode, text: "pair:\(nonce)")], to: peer)
        case (.host, "command"):
            guard authorizedPeer == peer else { return }
            if let message = onCommand?(message) { send(["type": "error", "message": message], to: peer) }
            lastState = Data()
        case (.remote, "paired"):
            guard !enteredCode.isEmpty,
                  let token = message["token"] as? String,
                  let proof = message["proof"] as? String,
                  proof == Self.proof(enteredCode, text: "pair:\(remoteNonce)") else {
                error = "Pairing response could not be verified."
                return
            }
            PeerSecret.save(token, key: "remote:\(peer.displayName)")
            verifiedHost = true; authorized = true; error = nil
        case (.remote, "challenge"):
            guard let token = PeerSecret.load("remote:\(peer.displayName)"),
                  let nonce = message["nonce"] as? String,
                  let proof = message["proof"] as? String,
                  proof == Self.proof(token, text: "host:\(remoteNonce)") else {
                error = "Host identity could not be verified. Pair again on the correct Host."
                session.disconnect()
                return
            }
            verifiedHost = true
            send(["type": "proof", "proof": Self.proof(token, text: "remote:\(nonce)")], to: peer)
        case (.remote, "state"):
            guard verifiedHost else { return }
            guard let messageRevision = message["revision"] as? Int,
                  messageRevision > receivedRevision,
                  let snapshot = message["state"] as? [String: Any] else { return }
            receivedRevision = messageRevision
            authorized = true; state = snapshot
        case (.remote, "error"):
            error = message["message"] as? String
        default: break
        }
    }

    private static func proof(_ token: String, text: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        return Data(HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)).base64EncodedString()
    }
}

extension PeerControl: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                guard session.connectedPeers.contains(peerID),
                      self.role == .host || self.activePeer == peerID else { return }
                self.connected = true
                if self.role == .remote {
                    self.authorized = false
                    self.verifiedHost = false
                    self.remoteNonce = UUID().uuidString
                    self.receivedRevision = 0
                    self.send(["type": "hello", "nonce": self.remoteNonce], to: peerID)
                }
            case .notConnected:
                self.connected = !session.connectedPeers.isEmpty
                if self.role == .host && self.authorizedPeer == peerID {
                    self.authorized = false; self.authorizedPeer = nil; self.onDisconnect?()
                }
                if self.role == .remote && self.activePeer == peerID {
                    self.authorized = false; self.verifiedHost = false; self.receivedRevision = 0
                }
                self.invited.remove(peerID.displayName)
            case .connecting: break
            @unknown default: break
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        DispatchQueue.main.async { self.receive(message, from: peerID) }
    }
    func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension PeerControl: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(role == .host, role == .host ? session : nil)
    }
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.error = error.localizedDescription }
    }
}

extension PeerControl: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        DispatchQueue.main.async {
            if !self.discovered.contains(peerID) { self.discovered.append(peerID) }
            if PeerSecret.load("remote:\(peerID.displayName)") != nil { self.connect(peerID) }
        }
    }
    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        DispatchQueue.main.async { self.discovered.removeAll { $0 == peerID } }
    }
    func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.error = error.localizedDescription }
    }
}

private enum PeerSecret {
    static func load(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FacePullPeer", kSecAttrAccount as String: key,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess,
              let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, key: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "FacePullPeer", kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        var item = query
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }
}

