import Foundation
import Network
import CoreImage
import CoreMedia

/// Single-port RTSP with RTP interleaved over TCP, so the same socket can cross usbmux.
final class H264RTSPServer {
    private final class Client {
        let connection: NWConnection
        var input = Data()
        var playing = false
        var awaitingKeyframe = true
        var sending = false
        var sequence = UInt16.random(in: 0...UInt16.max)
        var audioSequence = UInt16.random(in: 0...UInt16.max)
        var audioSending = false
        var videoChannel: UInt8?
        var audioChannel: UInt8?
        var lastProgress = Date()
        let sessionID = UUID().uuidString
        init(_ connection: NWConnection) { self.connection = connection }
    }

    var onError: ((String) -> Void)?
    var onStatus: ((Bool, String?) -> Void)?
    var onViewers: ((Int) -> Void)?
    private let queue = DispatchQueue(label: "facepull.rtsp", qos: .userInitiated)
    private let encoder = H264Encoder()
    private let microphone = MicrophoneAAC()
    private let deliveryGate = NSLock()
    private var deliveryPending = false
    private var deliveryDropped = false
    private var audioDeliveryPending = false
    private var audioAllowed = false
    private var hasViewers = false
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var timer: DispatchSourceTimer?
    private var token = ""
    private var running = false
    private var microphoneEnabled = false
    private var audioCaptureRunning = false
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private let audioSSRC = UInt32.random(in: 1...UInt32.max)

    init() {
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.deliveryGate.lock()
            guard !self.deliveryPending else {
                self.deliveryDropped = true
                self.deliveryGate.unlock(); return
            }
            self.deliveryPending = true
            self.deliveryGate.unlock()
            self.queue.async {
                self.send(frame)
                self.deliveryGate.lock()
                let dropped = self.deliveryDropped
                self.deliveryDropped = false; self.deliveryPending = false
                self.deliveryGate.unlock()
                if dropped {
                    // A skipped encoded P-frame breaks the decoder's reference
                    // chain. Resume with a fresh IDR, never with a dependent frame.
                    self.clients.values.forEach { $0.awaitingKeyframe = true }
                    self.encoder.requestKeyframe()
                }
            }
        }
        encoder.onError = { [weak self] message in self?.report(message) }
        microphone.onFrame = { [weak self] frame in
            guard let self else { return }
            self.deliveryGate.lock()
            guard !self.audioDeliveryPending else { self.deliveryGate.unlock(); return }
            self.audioDeliveryPending = true
            self.deliveryGate.unlock()
            self.queue.async {
                self.sendAudio(frame)
                self.deliveryGate.lock()
                self.audioDeliveryPending = false
                self.deliveryGate.unlock()
            }
        }
        microphone.onError = { [weak self] message in
            guard let self else { return }
            self.deliveryGate.lock()
            self.audioAllowed = false
            self.deliveryGate.unlock()
            self.queue.async {
                self.microphoneEnabled = false
                self.updateAudioCapture()
                self.report(message)
                DispatchQueue.main.async { self.onMicrophoneFailure?() }
            }
        }
    }

    var onMicrophoneFailure: (() -> Void)?

    func setMicrophoneEnabled(_ enabled: Bool) {
        deliveryGate.lock()
        audioAllowed = enabled
        deliveryGate.unlock()
        queue.async {
            self.microphoneEnabled = enabled
            self.updateAudioCapture()
        }
    }

    func start(token: String, size: CGSize, frameRate: Double) {
        queue.async {
            self.stopInternal()
            self.token = token
            self.encoder.start(size: size, frameRate: frameRate)
            do {
                let tcp = NWProtocolTCP.Options()
                tcp.noDelay = true
                let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: 8554)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.reportStatus(true)
                    case .failed(let error):
                        self.stopInternal()
                        self.reportStatus(false, error: "RTSP server stopped: \(error.localizedDescription)")
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                listener.start(queue: self.queue)
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + 5, repeating: 5)
                timer.setEventHandler { [weak self] in self?.expireClients() }
                timer.resume(); self.timer = timer
            } catch { self.reportStatus(false, error: "RTSP server could not start: \(error.localizedDescription)") }
        }
    }

    func stop() { queue.async { self.stopInternal() } }

    func offer(_ image: CIImage, time: CMTime) {
        deliveryGate.lock(); let needed = hasViewers; deliveryGate.unlock()
        guard needed else { return }
        encoder.offer(image, time: time)
    }

    private func stopInternal() {
        let hadListener = listener != nil
        running = false
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        for client in clients.values { client.connection.cancel() }
        clients.removeAll()
        updateAudioCapture()
        reportViewers()
        encoder.stop()
        if hadListener { reportStatus(false) }
    }

    private func accept(_ connection: NWConnection) {
        guard running, clients.count < 8 else { connection.cancel(); return }
        let id = UUID(), client = Client(connection)
        clients[id] = client
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.remove(id) }
            if case .cancelled = state { self?.remove(id) }
        }
        connection.start(queue: queue)
        read(id)
    }

    private func read(_ id: UUID) {
        guard let client = clients[id] else { return }
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self, self.clients[id] === client else { return }
            if error != nil || complete { self.remove(id); return }
            if let data { client.input.append(data) }
            guard client.input.count < 16_384 else { self.remove(id); return }
            self.parseRequests(id)
            self.read(id)
        }
    }

    private func parseRequests(_ id: UUID) {
        guard let client = clients[id] else { return }
        let end = Data("\r\n\r\n".utf8)
        while !client.input.isEmpty {
            if client.input.first == 0x24 {
                guard client.input.count >= 4 else { return }
                let length = Int(client.input[2]) << 8 | Int(client.input[3])
                guard client.input.count >= length + 4 else { return }
                client.input.removeSubrange(..<(length + 4))
                continue
            }
            guard let range = client.input.range(of: end) else { return }
            let header = Data(client.input[..<range.upperBound])
            client.input.removeSubrange(..<range.upperBound)
            guard let request = String(data: header, encoding: .utf8) else { remove(id); return }
            respond(request, id: id)
        }
    }

    private func respond(_ request: String, id: UUID) {
        guard let client = clients[id] else { return }
        let lines = request.components(separatedBy: "\r\n")
        let fields = lines.first?.split(separator: " ") ?? []
        guard fields.count >= 3, fields[2].hasPrefix("RTSP/") else { remove(id); return }
        let method = String(fields[0]).uppercased()
        let uri = String(fields[1])
        let cseq = lines.first(where: { $0.lowercased().hasPrefix("cseq:") })?
            .split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "0"
        if method == "OPTIONS" {
            reply(id, cseq: cseq, extra: "Public: OPTIONS, DESCRIBE, SETUP, PLAY, GET_PARAMETER, TEARDOWN\r\n")
            return
        }
        guard let url = URLComponents(string: uri),
              ["/facepull", "/facepull/trackID=0", "/facepull/trackID=1"].contains(url.path),
              url.queryItems?.first(where: { $0.name == "token" })?.value == token else {
            reply(id, cseq: cseq, status: "403 Forbidden"); return
        }
        switch method {
        case "DESCRIBE":
            guard url.path == "/facepull" else { reply(id, cseq: cseq, status: "400 Bad Request"); return }
            let videoControl = uri.replacingOccurrences(of: "?token=", with: "/trackID=0?token=")
            let audioControl = uri.replacingOccurrences(of: "?token=", with: "/trackID=1?token=")
            let sdp = "v=0\r\no=FacePull 0 0 IN IP4 127.0.0.1\r\ns=FacePull\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\r\na=control:\(videoControl)\r\nm=audio 0 RTP/AVP 97\r\na=rtpmap:97 MPEG4-GENERIC/48000/1\r\na=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;config=1188;SizeLength=13;IndexLength=3;IndexDeltaLength=3\r\na=control:\(audioControl)\r\n"
            reply(id, cseq: cseq, extra: "Content-Base: \(uri)\r\nContent-Type: application/sdp\r\n", body: sdp)
        case "SETUP":
            let transport = lines.first(where: { $0.lowercased().hasPrefix("transport:") })?.lowercased() ?? ""
            guard transport.contains("rtp/avp/tcp") && transport.contains("interleaved=") else {
                reply(id, cseq: cseq, status: "461 Unsupported Transport"); return
            }
            let isAudio = url.path == "/facepull/trackID=1"
            guard url.path != "/facepull",
                  let channelText = transport.components(separatedBy: "interleaved=").dropFirst().first?.split(separator: ";").first,
                  let first = UInt8(channelText.split(separator: "-").first ?? ""), first <= 252,
                  channelText == "\(first)-\(first + 1)", first.isMultiple(of: 2),
                  (isAudio ? client.videoChannel : client.audioChannel) != first else {
                reply(id, cseq: cseq, status: "461 Unsupported Transport"); return
            }
            if isAudio { client.audioChannel = first } else { client.videoChannel = first }
            let trackSSRC = isAudio ? audioSSRC : ssrc
            reply(id, cseq: cseq, extra: "Transport: RTP/AVP/TCP;unicast;interleaved=\(first)-\(first + 1);ssrc=\(String(trackSSRC, radix: 16))\r\nSession: \(client.sessionID);timeout=60\r\n")
        case "PLAY":
            guard client.videoChannel != nil || client.audioChannel != nil else { reply(id, cseq: cseq, status: "455 Method Not Valid in This State"); return }
            client.playing = true; client.awaitingKeyframe = true
            reportViewers()
            updateAudioCapture()
            encoder.requestKeyframe()
            reply(id, cseq: cseq, extra: "Session: \(client.sessionID)\r\n")
        case "GET_PARAMETER": reply(id, cseq: cseq, extra: "Session: \(client.sessionID)\r\n")
        case "TEARDOWN":
            reply(id, cseq: cseq, extra: "Session: \(client.sessionID)\r\n")
            client.playing = false
            reportViewers()
            updateAudioCapture()
        default: reply(id, cseq: cseq, status: "405 Method Not Allowed")
        }
    }

    private func reply(_ id: UUID, cseq: String, status: String = "200 OK", extra: String = "", body: String = "") {
        guard let client = clients[id] else { return }
        let data = Data("RTSP/1.0 \(status)\r\nCSeq: \(cseq)\r\nServer: FacePull\r\n\(extra)Content-Length: \(body.utf8.count)\r\n\r\n\(body)".utf8)
        client.connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.remove(id) }
        })
    }

    private func send(_ frame: H264Encoder.Frame) {
        guard running else { return }
        for (id, client) in clients where client.playing && client.videoChannel != nil {
            if client.sending { client.awaitingKeyframe = true; continue }
            if client.awaitingKeyframe && !frame.isKeyframe { continue }
            client.awaitingKeyframe = false
            var packet = Data()
            for (index, unit) in frame.nalUnits.enumerated() {
                packet.append(RTPH264.packetize(unit, sequence: &client.sequence, timestamp: frame.timestamp,
                    ssrc: ssrc, channel: client.videoChannel!, marker: index == frame.nalUnits.count - 1))
            }
            client.sending = true
            client.connection.send(content: packet, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client, self.clients[id] === client else { return }
                if error != nil { self.remove(id) }
                else { client.sending = false; client.lastProgress = Date() }
            })
        }
    }

    private func sendAudio(_ frame: MicrophoneAAC.Frame) {
        deliveryGate.lock()
        let allowed = audioAllowed
        deliveryGate.unlock()
        guard allowed else { return }
        guard running, microphoneEnabled, !frame.data.isEmpty, frame.data.count <= 1200 else { return }
        for (id, client) in clients where client.playing && client.audioChannel != nil {
            guard !client.audioSending else { continue }
            let packet = RTPAAC.packetize(frame.data, sequence: &client.audioSequence,
                timestamp: frame.timestamp, ssrc: audioSSRC, channel: client.audioChannel!)
            client.audioSending = true
            client.connection.send(content: packet, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client, self.clients[id] === client else { return }
                if error != nil { self.remove(id) }
                else { client.audioSending = false; client.lastProgress = Date() }
            })
        }
    }

    private func updateAudioCapture() {
        let needed = running && microphoneEnabled && clients.values.contains { $0.playing && $0.audioChannel != nil }
        guard needed != audioCaptureRunning else { return }
        audioCaptureRunning = needed
        if needed { microphone.start() } else { microphone.stop() }
    }

    private func remove(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
        reportViewers()
        updateAudioCapture()
    }

    private func expireClients() {
        let expired = clients.filter { Date().timeIntervalSince($0.value.lastProgress) > 20 }.map(\.key)
        expired.forEach(remove)
    }

    private func reportViewers() {
        let count = clients.values.filter { $0.playing && $0.videoChannel != nil }.count
        deliveryGate.lock(); hasViewers = count > 0; deliveryGate.unlock()
        DispatchQueue.main.async { [weak self] in self?.onViewers?(count) }
    }

    private func report(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onError?(message) }
    }

    private func reportStatus(_ active: Bool, error: String? = nil) {
        DispatchQueue.main.async { [weak self] in self?.onStatus?(active, error) }
    }
}

private enum RTPH264 {
    static func packetize(_ unit: Data, sequence: inout UInt16, timestamp: UInt32,
                          ssrc: UInt32, channel: UInt8, marker: Bool) -> Data {
        guard let first = unit.first else { return Data() }
        let bytes = [UInt8](unit)
        let payloadSize = 1200
        var output = Data()
        if bytes.count <= payloadSize {
            output.append(packet(Data(bytes), sequence: &sequence, timestamp: timestamp, ssrc: ssrc, channel: channel, marker: marker))
        } else {
            let indicator = (first & 0xe0) | 28
            let kind = first & 0x1f
            var offset = 1
            while offset < bytes.count {
                let count = min(payloadSize - 2, bytes.count - offset)
                let start = offset == 1, end = offset + count == bytes.count
                var fragment = Data([indicator, kind | (start ? 0x80 : 0) | (end ? 0x40 : 0)])
                fragment.append(contentsOf: bytes[offset..<(offset + count)])
                output.append(packet(fragment, sequence: &sequence, timestamp: timestamp, ssrc: ssrc, channel: channel, marker: marker && end))
                offset += count
            }
        }
        return output
    }

    private static func packet(_ payload: Data, sequence: inout UInt16, timestamp: UInt32,
                               ssrc: UInt32, channel: UInt8, marker: Bool) -> Data {
        let length = payload.count + 12
        var result = Data([0x24, channel, UInt8(length >> 8), UInt8(length & 0xff),
                           0x80, marker ? 0xe0 : 0x60,
                           UInt8(sequence >> 8), UInt8(sequence & 0xff),
                           UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
                           UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff),
                           UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xff),
                           UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff)])
        result.append(payload)
        sequence &+= 1
        return result
    }
}

private enum RTPAAC {
    static func packetize(_ accessUnit: Data, sequence: inout UInt16, timestamp: UInt32,
                          ssrc: UInt32, channel: UInt8) -> Data {
        // RFC 3640: one AAC-hbr access unit, 16-bit AU-header-length and
        // 13-bit AU-size followed by a zero AU-index.
        let size = accessUnit.count
        let length = size + 16
        var packet = Data([0x24, channel, UInt8(length >> 8), UInt8(length & 0xff),
                           0x80, 0xe1, UInt8(sequence >> 8), UInt8(sequence & 0xff),
                           UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
                           UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff),
                           UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xff),
                           UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff),
                           0, 16, UInt8(size >> 5), UInt8((size & 0x1f) << 3)])
        packet.append(accessUnit)
        sequence &+= 1
        return packet
    }
}
