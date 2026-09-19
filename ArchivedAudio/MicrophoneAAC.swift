import AVFAudio
import Foundation
import CoreMedia

/// Captures only while an RTSP audio consumer is active. The tap copies PCM and
/// all conversion work runs on its own bounded queue, away from video capture.
final class MicrophoneAAC {
    struct Frame {
        let data: Data
        let timestamp: UInt32
        let silent: Bool
    }

    var onFrame: ((Frame) -> Void)?
    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "facepull.aac", qos: .userInitiated)
    private let admission = NSLock()
    private var pending = false
    private var generation = 0
    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    private var outputFormat: AVAudioFormat?
    private var nextTimestamp: UInt32 = 0
    private var hasTimestamp = false
    private var framesPerPacket: UInt32 = 0
    private var running = false
    private var enabled = false
    private var awaitingLive = false
    private var silence: Data?
    private var silenceTimer: DispatchSourceTimer?
    private var lastEmittedTimestamp: UInt32?
    private var compressedBuffer: AVAudioCompressedBuffer?

    func start(microphoneEnabled: Bool) {
        queue.async {
            guard !self.running else { self.changeMicrophone(microphoneEnabled); return }
            self.running = true
            self.lastEmittedTimestamp = nil
            if self.silence == nil { self.silence = Self.makeSilence() }
            if self.silence == nil { self.onError?("AAC silence initialization failed; the reserved audio track cannot be kept active.") }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 1024.0 / 48_000.0, leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.sendSilence() }
            self.silenceTimer = timer
            timer.resume()
            self.changeMicrophone(microphoneEnabled)
        }
    }

    func setMicrophoneEnabled(_ enabled: Bool) {
        queue.async { self.changeMicrophone(enabled) }
    }

    private func changeMicrophone(_ enabled: Bool) {
        guard running else { return }
        self.enabled = enabled
        if enabled {
            guard engine == nil else { return }
            awaitingLive = true
            startCapture()
        } else {
            stopCapture()
            awaitingLive = false
        }
    }

    private func startCapture() {
            do {
                let engine = AVAudioEngine()
                let input = engine.inputNode
                let inputFormat = input.outputFormat(forBus: 0)
                guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
                      inputFormat.commonFormat == .pcmFormatFloat32, !inputFormat.isInterleaved,
                      let output = AVAudioFormat(settings: [
                        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                        AVSampleRateKey: 48_000,
                        AVNumberOfChannelsKey: 1,
                        AVEncoderBitRateKey: 96_000
                      ]),
                      let converter = AVAudioConverter(from: inputFormat, to: output) else {
                    self.onError?("Microphone AAC format is unavailable.")
                    return
                }
                converter.bitRate = 96_000
                let description = converter.outputFormat.streamDescription.pointee
                guard description.mSampleRate == 48_000, description.mChannelsPerFrame == 1,
                      description.mFormatID == kAudioFormatMPEG4AAC else {
                    self.onError?("Microphone AAC format is \(description.mSampleRate) Hz, \(description.mChannelsPerFrame) channels, codec \(description.mFormatID); expected AAC-LC 48000 Hz mono.")
                    return
                }
                self.converter = converter
                self.outputFormat = output
                self.compressedBuffer = AVAudioCompressedBuffer(format: output, packetCapacity: 1,
                    maximumPacketSize: max(4096, converter.maximumOutputPacketSize))
                // AVAudioFormat(settings:) may leave this ASBD field unspecified.
                // AAC-LC access units contain 1024 PCM frames (Core Audio format spec).
                self.framesPerPacket = description.mFramesPerPacket == 0 ? 1024 : description.mFramesPerPacket
                self.nextTimestamp = UInt32(truncatingIfNeeded: Int64(ProcessInfo.processInfo.systemUptime * 48_000))
                self.hasTimestamp = false
                let generation = self.generation
                input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, time in
                    self?.accept(buffer, time: time, generation: generation)
                }
                self.engine = engine
                engine.prepare()
                try engine.start()
            } catch {
                self.stopCapture()
                self.onError?("Microphone capture failed: \(error.localizedDescription)")
            }
    }

    func stop() {
        queue.async {
            self.running = false
            self.silenceTimer?.cancel(); self.silenceTimer = nil
            self.stopCapture()
            self.lastEmittedTimestamp = nil
        }
    }

    private func stopCapture() {
        admission.lock()
        generation &+= 1
        pending = false
        admission.unlock()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        converter = nil
        outputFormat = nil
        compressedBuffer = nil
    }

    private func accept(_ buffer: AVAudioPCMBuffer, time: AVAudioTime, generation: Int) {
        admission.lock()
        guard self.generation == generation, !pending else { admission.unlock(); return }
        pending = true
        admission.unlock()
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength),
              let source = buffer.floatChannelData, let destination = copy.floatChannelData else {
            release(generation: generation)
            return
        }
        copy.frameLength = buffer.frameLength
        for channel in 0..<Int(buffer.format.channelCount) {
            destination[channel].update(from: source[channel], count: Int(buffer.frameLength))
        }
        let timestamp = time.isHostTimeValid
            ? UInt32(truncatingIfNeeded: Int64(AVAudioTime.seconds(forHostTime: time.hostTime) * 48_000))
            : UInt32(truncatingIfNeeded: Int64(ProcessInfo.processInfo.systemUptime * 48_000))
        queue.async {
            defer { self.release(generation: generation) }
            self.encode(copy, timestamp: timestamp, generation: generation)
        }
    }

    private func release(generation: Int) {
        admission.lock()
        if self.generation == generation { pending = false }
        admission.unlock()
    }

    private func encode(_ pcm: AVAudioPCMBuffer, timestamp: UInt32, generation: Int) {
        guard running, enabled, self.generation == generation, let converter, let compressed = compressedBuffer else { return }
        var supplied = false
        // A resampler can produce more than one AAC access unit from one tap.
        // Drain it so the converter cannot accumulate old microphone samples.
        for _ in 0..<8 {
            compressed.packetCount = 0
            compressed.byteLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: compressed, error: &conversionError) { _, inputStatus in
                if supplied { inputStatus.pointee = .noDataNow; return nil }
                supplied = true
                inputStatus.pointee = .haveData
                return pcm
            }
            if let conversionError {
                onError?("Microphone AAC encoding failed: \(conversionError.localizedDescription)")
                return
            }
            guard status != .error else { onError?("Microphone AAC encoding failed."); return }
            guard compressed.packetCount > 0, compressed.byteLength > 0 else { return }
            let offset = compressed.packetDescriptions.map { Int($0[0].mStartOffset) } ?? 0
            let size = compressed.packetDescriptions.map { Int($0[0].mDataByteSize) } ?? Int(compressed.byteLength)
            guard offset >= 0, size > 0, offset + size <= Int(compressed.byteLength) else {
                onError?("Microphone AAC packet boundary is invalid.")
                return
            }
            if !hasTimestamp || Int32(bitPattern: timestamp &- nextTimestamp) > 12_000 {
                nextTimestamp = timestamp
                hasTimestamp = true
            }
            let data = Data(bytes: compressed.data.advanced(by: offset), count: size)
            awaitingLive = false
            emit(data, timestamp: nextTimestamp, silent: false)
            nextTimestamp &+= framesPerPacket
            if status != .haveData { return }
        }
    }

    private func emit(_ data: Data, timestamp: UInt32, silent: Bool) {
        if let last = lastEmittedTimestamp, Int32(bitPattern: timestamp &- last) <= 0 { return }
        lastEmittedTimestamp = timestamp
        if !silent && StreamDiagnostics.isEnabled {
            let now = UInt32(truncatingIfNeeded: Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 48_000))
            StreamDiagnostics.sample("Audio capture to emit", milliseconds:
                Double(Int32(bitPattern: now &- timestamp)) / 48)
        }
        onFrame?(Frame(data: data, timestamp: timestamp, silent: silent))
    }

    private func sendSilence() {
        guard running, !enabled || awaitingLive, let silence else { return }
        let now = UInt32(truncatingIfNeeded: Int64(CMClockGetTime(CMClockGetHostTimeClock()).seconds * 48_000))
        let next = lastEmittedTimestamp.map { $0 &+ 1024 } ?? now
        guard Int32(bitPattern: now &- next) >= 0 else { return }
        emit(silence, timestamp: Int32(bitPattern: now &- next) > 2048 ? now : next, silent: true)
    }

    // Encode once with the same AAC-LC/48 kHz/mono configuration as live audio.
    // Muting stops microphone capture; only this cached silent AU keeps the
    // negotiated RTSP track alive, so OBS never waits for a missing track.
    private static func makeSilence() -> Data? {
        guard let pcmFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let pcm = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: 1024),
              let output = AVAudioFormat(settings: [AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000]),
              let converter = AVAudioConverter(from: pcmFormat, to: output) else { return nil }
        pcm.frameLength = 1024
        pcm.floatChannelData?[0].initialize(repeating: 0, count: 1024)
        converter.bitRate = 96_000
        let compressed = AVAudioCompressedBuffer(format: output, packetCapacity: 1,
                                                maximumPacketSize: max(4096, converter.maximumOutputPacketSize))
        for _ in 0..<8 {
            compressed.packetCount = 0
            compressed.byteLength = 0
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: compressed, error: &error) { _, state in
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true; state.pointee = .haveData; return pcm
            }
            guard status != .error, error == nil else { return nil }
            if compressed.packetCount > 0 {
                let offset = compressed.packetDescriptions.map { Int($0[0].mStartOffset) } ?? 0
                let count = compressed.packetDescriptions.map { Int($0[0].mDataByteSize) } ?? Int(compressed.byteLength)
                guard offset >= 0, count > 0, offset + count <= Int(compressed.byteLength) else { return nil }
                return Data(bytes: compressed.data.advanced(by: offset), count: count)
            }
        }
        return nil
    }
}
