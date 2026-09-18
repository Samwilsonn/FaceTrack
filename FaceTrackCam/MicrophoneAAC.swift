import AVFAudio
import Foundation

/// Captures only while an RTSP audio consumer is active. The tap copies PCM and
/// all conversion work runs on its own bounded queue, away from video capture.
final class MicrophoneAAC {
    struct Frame {
        let data: Data
        let timestamp: UInt32
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

    func start() {
        queue.async {
            guard self.engine == nil else { return }
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
                self.stopInternal()
                self.onError?("Microphone capture failed: \(error.localizedDescription)")
            }
        }
    }

    func stop() { queue.async { self.stopInternal() } }

    private func stopInternal() {
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
        guard self.generation == generation, let converter, let outputFormat else { return }
        var supplied = false
        // A resampler can produce more than one AAC access unit from one tap.
        // Drain it so the converter cannot accumulate old microphone samples.
        for _ in 0..<8 {
            let compressed = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1,
                                                     maximumPacketSize: max(4096, converter.maximumOutputPacketSize))
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
            onFrame?(Frame(data: data, timestamp: nextTimestamp))
            nextTimestamp &+= framesPerPacket
            if status != .haveData { return }
        }
    }
}
