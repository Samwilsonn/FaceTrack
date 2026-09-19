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
        var videoSendStarted: Date?
        var audioSendStarted: Date?
        var lastClockReport = Date.distantPast
        var sequence = UInt16.random(in: 0...UInt16.max)
        var audioSequence = UInt16.random(in: 0...UInt16.max)
        var audioSending = false
        var videoChannel: UInt8?
        var audioChannel: UInt8?
        var audioOffered = false
        var videoControl = ""
        var audioControl = ""
        var videoPackets: UInt32 = 0
        var videoOctets: UInt32 = 0
        var audioPackets: UInt32 = 0
        var audioOctets: UInt32 = 0
        var pendingAudio: [MicrophoneAAC.Frame] = []
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
    private let remotePreview = RemotePreviewChannel(host: true)
    private var previewWanted = false
    private var previewToken = ""
    private var hasPreview = false
    var previewName: String { remotePreview.name }
    private let deliveryGate = NSLock()
    private var deliveryPending = false
    private var deliveryDropped = false
    private var audioDeliveryQueued = false
    private var audioFrames: [MicrophoneAAC.Frame] = []
    private var audioAllowed = false
    private var hasViewers = false
    private var latestVideoTimestamp: UInt32?
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
        remotePreview.onDemand = { [weak self] enabled in
            guard let self else { return }
            self.deliveryGate.lock(); self.hasPreview = enabled; self.deliveryGate.unlock()
        }
        remotePreview.onKeyframe = { [weak self] in self?.encoder.requestKeyframe() }
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.remotePreview.offer(frame)
            self.deliveryGate.lock()
            guard self.hasViewers else { self.deliveryGate.unlock(); return }
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
            guard self.audioAllowed else { self.deliveryGate.unlock(); return }
            if self.audioFrames.count == 8 { self.audioFrames.removeFirst() }
            self.audioFrames.append(frame)
            guard !self.audioDeliveryQueued else { self.deliveryGate.unlock(); return }
            self.audioDeliveryQueued = true
            self.deliveryGate.unlock()
            self.queue.async { self.drainAudio() }
        }
        microphone.onError = { [weak self] message in
            guard let self else { return }
            self.deliveryGate.lock()
            self.audioFrames.removeAll()
            self.deliveryGate.unlock()
            self.queue.async {
                self.microphoneEnabled = false
                self.microphone.setMicrophoneEnabled(false)
                self.report(message)
                DispatchQueue.main.async { self.onMicrophoneFailure?() }
            }
        }
    }

    var onMicrophoneFailure: (() -> Void)?

    func setPreviewEnabled(_ enabled: Bool, token: String) {
        queue.async {
            self.previewWanted = enabled; self.previewToken = token
            self.updatePreview()
        }
    }

    private func updatePreview() {
        if running && previewWanted { remotePreview.start(token: previewToken) }
        else { remotePreview.stop() }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        deliveryGate.lock()
        if !enabled { audioFrames.removeAll() }
        deliveryGate.unlock()
        queue.async {
            self.microphoneEnabled = enabled
            if !enabled { self.clients.values.forEach { $0.pendingAudio.removeAll() } }
            self.microphone.setMicrophoneEnabled(enabled)
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
                // Use normal TCP startup/retransmission behavior. The bounded
                // media-send watchdog below aborts genuinely blocked sessions.
                let listener = try NWListener(using: NWParameters(tls: nil, tcp: tcp), on: 8554)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        self.running = true
                        self.updatePreview()
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
                timer.schedule(deadline: .now() + 0.1, repeating: 0.1, leeway: .milliseconds(10))
                timer.setEventHandler { [weak self] in self?.expireClients() }
                timer.resume(); self.timer = timer
            } catch { self.reportStatus(false, error: "RTSP server could not start: \(error.localizedDescription)") }
        }
    }

    func stop() { queue.async { self.stopInternal() } }

    func offer(_ image: CIImage, time: CMTime) {
        deliveryGate.lock()
        let needed = hasViewers || hasPreview
        if needed && time.isValid {
            latestVideoTimestamp = UInt32(truncatingIfNeeded: Int64((time.seconds * 90_000).rounded()))
        }
        deliveryGate.unlock()
        guard needed else { return }
        encoder.offer(image, time: time)
    }

    private func stopInternal() {
        let hadListener = listener != nil
        running = false
        remotePreview.stop()
        deliveryGate.lock()
        audioFrames.removeAll()
        latestVideoTimestamp = nil
        deliveryGate.unlock()
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        for client in clients.values { client.connection.forceCancel() }
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
            client.audioOffered = true
            client.videoControl = videoControl
            client.audioControl = audioControl
            var sdp = "v=0\r\no=FacePull 0 0 IN IP4 127.0.0.1\r\ns=FacePull\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\r\na=control:\(videoControl)\r\n"
            if client.audioOffered {
                sdp += "m=audio 0 RTP/AVP 97\r\na=rtpmap:97 MPEG4-GENERIC/48000/1\r\na=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;config=1188;constantDuration=1024;SizeLength=13;IndexLength=3;IndexDeltaLength=3\r\na=control:\(audioControl)\r\n"
            }
            reply(id, cseq: cseq, extra: "Content-Base: \(uri)\r\nContent-Type: application/sdp\r\n", body: sdp)
        case "SETUP":
            let transport = lines.first(where: { $0.lowercased().hasPrefix("transport:") })?.lowercased() ?? ""
            guard transport.contains("rtp/avp/tcp") && transport.contains("interleaved=") else {
                reply(id, cseq: cseq, status: "461 Unsupported Transport"); return
            }
            let isAudio = url.path == "/facepull/trackID=1"
            guard url.path != "/facepull", (!isAudio || client.audioOffered),
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
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            var info: [String] = []
            if client.videoChannel != nil { info.append("url=\(client.videoControl);seq=\(client.sequence);rtptime=\(LiveStreamClock.ticks(hostTime, rate: 90_000))") }
            if client.audioChannel != nil { info.append("url=\(client.audioControl);seq=\(client.audioSequence);rtptime=\(LiveStreamClock.ticks(hostTime, rate: 48_000))") }
            reply(id, cseq: cseq, extra: "Session: \(client.sessionID)\r\nRange: npt=0.000-\r\nRTP-Info: \(info.joined(separator: ","))\r\n")
            client.playing = true; client.awaitingKeyframe = true
            client.lastProgress = Date()
            sendClockReport(id, client: client)
            reportViewers()
            updateAudioCapture()
            encoder.requestKeyframe()
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
        deliveryGate.lock()
        let latest = latestVideoTimestamp
        deliveryGate.unlock()
        let nowStamp = LiveStreamClock.ticks(CMClockGetTime(CMClockGetHostTimeClock()).seconds, rate: 90_000)
        StreamDiagnostics.sample("Capture to RTP", milliseconds: Double(Int32(bitPattern: nowStamp &- frame.timestamp)) / 90)
        if Int32(bitPattern: nowStamp &- frame.timestamp) > 18_000 ||
            latest.map({ Int32(bitPattern: $0 &- frame.timestamp) > 18_000 }) == true {
            clients.values.forEach { $0.awaitingKeyframe = true }
            encoder.requestKeyframe()
            return
        }
        for (id, client) in clients where client.playing && client.videoChannel != nil {
            if client.sending { client.awaitingKeyframe = true; continue }
            if client.awaitingKeyframe && !frame.isKeyframe { continue }
            client.awaitingKeyframe = false
            var packet = Data()
            let previousSequence = client.sequence
            for (index, unit) in frame.nalUnits.enumerated() {
                packet.append(RTPH264.packetize(unit, sequence: &client.sequence, timestamp: frame.timestamp,
                    ssrc: ssrc, channel: client.videoChannel!, marker: index == frame.nalUnits.count - 1))
            }
            client.sending = true
            let packetCount = UInt32(client.sequence &- previousSequence)
            client.videoPackets &+= packetCount
            client.videoOctets &+= UInt32(max(0, packet.count - Int(packetCount) * 16))
            client.videoSendStarted = Date()
            client.connection.send(content: packet, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client, self.clients[id] === client else { return }
                if error != nil { self.remove(id) }
                else {
                    let elapsed = client.videoSendStarted.map { Date().timeIntervalSince($0) } ?? 0
                    StreamDiagnostics.sample("TCP write processed", milliseconds: elapsed * 1000)
                    if RTSPSendDeadline.isExpired(startedAt: client.videoSendStarted?.timeIntervalSinceReferenceDate,
                                                   now: Date().timeIntervalSinceReferenceDate) { self.remove(id); return }
                    client.sending = false; client.videoSendStarted = nil; client.lastProgress = Date()
                    if client.awaitingKeyframe { self.encoder.requestKeyframe() }
                }
            })
        }
    }

    private func drainAudio() {
        deliveryGate.lock()
        let frames = audioFrames
        audioFrames.removeAll(keepingCapacity: true)
        audioDeliveryQueued = false
        deliveryGate.unlock()
        guard running else { return }
        for (id, client) in clients where client.playing && client.audioChannel != nil {
            client.pendingAudio.append(contentsOf: frames.filter { microphoneEnabled || $0.silent })
            if client.pendingAudio.count > 8 { client.pendingAudio.removeFirst(client.pendingAudio.count - 8) }
            sendAudio(id, client: client)
        }
    }

    private func sendAudio(_ id: UUID, client: Client) {
            guard running, client.playing, let channel = client.audioChannel,
                  !client.audioSending, !client.pendingAudio.isEmpty else { return }
            var packet = Data()
            let now = LiveStreamClock.ticks(CMClockGetTime(CMClockGetHostTimeClock()).seconds, rate: 48_000)
            for frame in client.pendingAudio where !frame.data.isEmpty && frame.data.count <= 8191 {
                guard Int32(bitPattern: now &- frame.timestamp) < 12_000 else { continue }
                packet.append(RTPAAC.packetize(frame.data, sequence: &client.audioSequence,
                    timestamp: frame.timestamp, ssrc: audioSSRC, channel: channel))
                client.audioPackets &+= 1
                client.audioOctets &+= UInt32(frame.data.count + 4)
            }
            client.pendingAudio.removeAll(keepingCapacity: true)
            guard !packet.isEmpty else { return }
            client.audioSending = true
            client.audioSendStarted = Date()
            client.connection.send(content: packet, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client, self.clients[id] === client else { return }
                if error != nil { self.remove(id) }
                else {
                    if RTSPSendDeadline.isExpired(startedAt: client.audioSendStarted?.timeIntervalSinceReferenceDate,
                                                   now: Date().timeIntervalSinceReferenceDate) {
                        self.remove(id); return
                    }
                    client.audioSending = false; client.audioSendStarted = nil
                    client.lastProgress = Date(); self.sendAudio(id, client: client)
                }
            })
    }

    private func updateAudioCapture() {
        let needed = running && clients.values.contains { $0.playing && $0.audioChannel != nil }
        deliveryGate.lock(); audioAllowed = needed; deliveryGate.unlock()
        guard needed != audioCaptureRunning else { return }
        audioCaptureRunning = needed
        if needed { microphone.start(microphoneEnabled: microphoneEnabled) } else { microphone.stop() }
    }

    private func remove(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.stateUpdateHandler = nil
        // Abort, do not gracefully drain a stale live-media socket.
        client.pendingAudio.removeAll()
        client.connection.forceCancel()
        reportViewers()
        updateAudioCapture()
    }

    private func expireClients() {
        let now = Date()
        let expired = clients.filter { entry in
            let client = entry.value
            // Available TCP buffer space is not queued-byte age or evidence of
            // a stall. It can stay small on a healthy, actively draining socket.
            return now.timeIntervalSince(client.lastProgress) > 6 ||
                RTSPSendDeadline.isExpired(startedAt: client.videoSendStarted?.timeIntervalSinceReferenceDate,
                                           now: now.timeIntervalSinceReferenceDate) ||
                RTSPSendDeadline.isExpired(startedAt: client.audioSendStarted?.timeIntervalSinceReferenceDate,
                                           now: now.timeIntervalSinceReferenceDate)
        }.map(\.key)
        expired.forEach(remove)
        for (id, client) in clients where client.playing && !client.sending && !client.audioSending && now.timeIntervalSince(client.lastClockReport) >= 1 {
            sendClockReport(id, client: client)
        }
    }

    private func sendClockReport(_ id: UUID, client: Client) {
        client.lastClockReport = Date()
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let wall = Date().timeIntervalSince1970
        var report = Data()
        if let channel = client.videoChannel {
            report.append(LiveStreamClock.report(channel: channel + 1, ssrc: ssrc,
                timestamp: LiveStreamClock.ticks(host, rate: 90_000), unixTime: wall,
                packets: client.videoPackets, octets: client.videoOctets))
        }
        if let channel = client.audioChannel {
            report.append(LiveStreamClock.report(channel: channel + 1, ssrc: audioSSRC,
                timestamp: LiveStreamClock.ticks(host, rate: 48_000), unixTime: wall,
                packets: client.audioPackets, octets: client.audioOctets))
        }
        client.connection.send(content: report, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.remove(id) }
        })
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
        var packet = Data([0x24, channel, UInt8(length >> 8), UInt8(length & 0xff)])
        packet.append(contentsOf: [0x80, 0xe1, UInt8(sequence >> 8), UInt8(sequence & 0xff)])
        packet.append(contentsOf: [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
                                   UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff)])
        packet.append(contentsOf: [UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xff),
                                   UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff)])
        packet.append(contentsOf: [0, 16, UInt8(size >> 5), UInt8((size & 0x1f) << 3)])
        packet.append(accessUnit)
        sequence &+= 1
        return packet
    }
}
