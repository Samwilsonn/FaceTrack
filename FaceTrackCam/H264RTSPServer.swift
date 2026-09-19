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
        var videoSendStarted: TimeInterval?
        var lastClockReport = -Double.infinity
        var sequence = UInt16.random(in: 0...UInt16.max)
        var videoChannel: UInt8?
        var videoControl = ""
        var videoPackets: UInt32 = 0
        var videoOctets: UInt32 = 0
        var lastProgress = ProcessInfo.processInfo.systemUptime
        let sessionID = UUID().uuidString
        init(_ connection: NWConnection) { self.connection = connection }
    }

    var onError: ((String) -> Void)?
    var onStatus: ((Bool, String?) -> Void)?
    var onViewers: ((Int) -> Void)?
    private let queue = DispatchQueue(label: "facepull.rtsp", qos: .userInitiated)
    private let encoder = H264Encoder()
    private let remotePreview = RemotePreviewChannel(host: true)
    private var previewWanted = false
    private var previewToken = ""
    private var hasPreview = false
    var previewName: String { remotePreview.name }
    private let deliveryGate = NSLock()
    private var deliveryPending = false
    private var deliveryDropped = false
    private var hasViewers = false
    private var needsFormat = false
    private var encoderReady = false
    private var generation = 0
    private var videoFormat: VideoStreamDescription.Format?
    private var frameRate = 30
    private var latestVideoTimestamp: UInt32?
    private var listener: NWListener?
    private var clients: [UUID: Client] = [:]
    private var timer: DispatchSourceTimer?
    private var token = ""
    private var running = false
    private let ssrc = UInt32.random(in: 1...UInt32.max)

    init() {
        remotePreview.onDemand = { [weak self] enabled in
            guard let self else { return }
            self.deliveryGate.lock(); self.hasPreview = enabled; self.deliveryGate.unlock()
        }
        remotePreview.onKeyframe = { [weak self] in self?.encoder.requestKeyframe() }
        encoder.onFrame = { [weak self] frame in
            guard let self else { return }
            self.deliveryGate.lock()
            guard self.encoderReady else { self.deliveryGate.unlock(); return }
            let generation = self.generation
            self.deliveryGate.unlock()
            self.remotePreview.offer(frame)
            self.deliveryGate.lock()
            guard self.generation == generation else { self.deliveryGate.unlock(); return }
            if self.needsFormat, let format = VideoStreamDescription.Format(units: frame.nalUnits) {
                self.needsFormat = false
                self.queue.async {
                    guard self.generation == generation else { return }
                    self.videoFormat = format
                }
            }
            guard self.hasViewers else { self.deliveryGate.unlock(); return }
            guard !self.deliveryPending else {
                self.deliveryDropped = true
                self.deliveryGate.unlock(); return
            }
            self.deliveryPending = true
            self.deliveryGate.unlock()
            self.queue.async {
                guard self.generation == generation else { return }
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
    }

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

    func start(token: String, size: CGSize, frameRate: Double) {
        queue.async {
            self.stopInternal()
            self.token = token
            self.frameRate = Int(frameRate)
            let generation = self.generation
            self.encoder.start(size: size, frameRate: frameRate) { [weak self] ready in
                guard let self else { return }
                self.queue.async {
                    guard self.generation == generation else { return }
                    guard ready else {
                        self.stopInternal()
                        self.reportStatus(false, error: "H.264 encoder could not start. Retry the stream.")
                        return
                    }
                    self.deliveryGate.lock(); self.encoderReady = true; self.deliveryGate.unlock()
                    if self.running { self.reportStatus(true) }
                }
            }
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
                        // Encode only enough real camera frames to obtain this
                        // session's headers before OBS asks for its description.
                        self.deliveryGate.lock(); self.needsFormat = self.videoFormat == nil; self.deliveryGate.unlock()
                        self.updatePreview()
                        if self.encoderReady { self.reportStatus(true) }
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
            } catch {
                self.stopInternal()
                self.reportStatus(false, error: "RTSP server could not start: \(error.localizedDescription)")
            }
        }
    }

    func stop() { queue.async { self.stopInternal() } }

    func offer(_ image: CIImage, time: CMTime) {
        deliveryGate.lock()
        let needed = encoderReady && (hasViewers || hasPreview || needsFormat)
        if needed && time.isNumeric && time.seconds.isFinite && time.seconds >= 0 {
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
        generation &+= 1
        encoderReady = false
        needsFormat = false
        deliveryPending = false; deliveryDropped = false
        latestVideoTimestamp = nil
        deliveryGate.unlock()
        videoFormat = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        timer?.cancel(); timer = nil
        for client in clients.values { client.connection.forceCancel() }
        clients.removeAll()
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
              VideoStreamDescription.accepts(path: url.path),
              url.queryItems?.first(where: { $0.name == "token" })?.value == token else {
            reply(id, cseq: cseq, status: "403 Forbidden"); return
        }
        switch method {
        case "DESCRIBE":
            guard url.path == "/facepull" else { reply(id, cseq: cseq, status: "400 Bad Request"); return }
            guard let videoControl = VideoStreamDescription.videoControlURL(uri) else {
                reply(id, cseq: cseq, status: "400 Bad Request"); return
            }
            client.videoControl = videoControl
            let sdp = VideoStreamDescription.sdp(control: videoControl, frameRate: frameRate, format: videoFormat)
            reply(id, cseq: cseq, extra: "Content-Base: \(uri)\r\nContent-Type: application/sdp\r\n", body: sdp)
        case "SETUP":
            let transport = lines.first(where: { $0.lowercased().hasPrefix("transport:") })?.lowercased() ?? ""
            guard transport.contains("rtp/avp/tcp") && transport.contains("interleaved=") else {
                reply(id, cseq: cseq, status: "461 Unsupported Transport"); return
            }
            guard url.path == "/facepull/trackID=0",
                  let channelText = transport.components(separatedBy: "interleaved=").dropFirst().first?.split(separator: ";").first,
                  let first = UInt8(channelText.split(separator: "-").first ?? ""), first <= 252,
                  channelText == "\(first)-\(first + 1)", first.isMultiple(of: 2) else {
                reply(id, cseq: cseq, status: "461 Unsupported Transport"); return
            }
            client.videoChannel = first
            reply(id, cseq: cseq, extra: "Transport: RTP/AVP/TCP;unicast;interleaved=\(first)-\(first + 1);ssrc=\(String(ssrc, radix: 16))\r\nSession: \(client.sessionID);timeout=60\r\n")
        case "PLAY":
            guard client.videoChannel != nil else { reply(id, cseq: cseq, status: "455 Method Not Valid in This State"); return }
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock()).seconds
            var info: [String] = []
            if client.videoChannel != nil { info.append("url=\(client.videoControl);seq=\(client.sequence);rtptime=\(LiveStreamClock.ticks(hostTime, rate: 90_000))") }
            reply(id, cseq: cseq, extra: "Session: \(client.sessionID)\r\nRange: npt=0.000-\r\nRTP-Info: \(info.joined(separator: ","))\r\n")
            client.playing = true; client.awaitingKeyframe = true
            client.lastProgress = ProcessInfo.processInfo.systemUptime
            sendClockReport(id, client: client)
            reportViewers()
            encoder.requestKeyframe()
        case "GET_PARAMETER": reply(id, cseq: cseq, extra: "Session: \(client.sessionID)\r\n")
        case "TEARDOWN":
            reply(id, cseq: cseq, extra: "Session: \(client.sessionID)\r\n")
            client.playing = false
            reportViewers()
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
            let packetizationStarted = StreamDiagnostics.isEnabled ? ProcessInfo.processInfo.systemUptime : 0
            for (index, unit) in frame.nalUnits.enumerated() {
                packet.append(RTPH264.packetize(unit, sequence: &client.sequence, timestamp: frame.timestamp,
                    ssrc: ssrc, channel: client.videoChannel!, marker: index == frame.nalUnits.count - 1))
            }
            StreamDiagnostics.elapsed("Video packetization", since: packetizationStarted)
            client.sending = true
            let packetCount = UInt32(client.sequence &- previousSequence)
            client.videoPackets &+= packetCount
            client.videoOctets &+= UInt32(max(0, packet.count - Int(packetCount) * 16))
            client.videoSendStarted = ProcessInfo.processInfo.systemUptime
            client.connection.send(content: packet, completion: .contentProcessed { [weak self, weak client] error in
                guard let self, let client, self.clients[id] === client else { return }
                if error != nil { self.remove(id) }
                else {
                    let now = ProcessInfo.processInfo.systemUptime
                    let elapsed = client.videoSendStarted.map { now - $0 } ?? 0
                    StreamDiagnostics.sample("TCP write processed", milliseconds: elapsed * 1000)
                    if RTSPSendDeadline.isExpired(startedAt: client.videoSendStarted, now: now) { self.remove(id); return }
                    client.sending = false; client.videoSendStarted = nil; client.lastProgress = now
                    if client.awaitingKeyframe { self.encoder.requestKeyframe() }
                }
            })
        }
    }

    private func remove(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.stateUpdateHandler = nil
        // Abort, do not gracefully drain a stale live-media socket.
        client.connection.forceCancel()
        reportViewers()
    }

    private func expireClients() {
        let now = ProcessInfo.processInfo.systemUptime
        let expired = clients.filter { entry in
            let client = entry.value
            // Available TCP buffer space is not queued-byte age or evidence of
            // a stall. It can stay small on a healthy, actively draining socket.
            return now - client.lastProgress > 6 ||
                RTSPSendDeadline.isExpired(startedAt: client.videoSendStarted, now: now)
        }.map(\.key)
        expired.forEach(remove)
        for (id, client) in clients where client.playing && !client.sending && now - client.lastClockReport >= 1 {
            sendClockReport(id, client: client)
        }
    }

    private func sendClockReport(_ id: UUID, client: Client) {
        client.lastClockReport = ProcessInfo.processInfo.systemUptime
        let host = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let wall = Date().timeIntervalSince1970
        var report = Data()
        if let channel = client.videoChannel {
            report.append(LiveStreamClock.report(channel: channel + 1, ssrc: ssrc,
                timestamp: LiveStreamClock.ticks(host, rate: 90_000), unixTime: wall,
                packets: client.videoPackets, octets: client.videoOctets))
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
