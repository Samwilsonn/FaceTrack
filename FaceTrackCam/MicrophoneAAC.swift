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
                self.converter = converter
                self.outputFormat = output
                self.nextTimestamp = UInt32(truncatingIfNeeded: Int64(ProcessInfo.processInfo.systemUptime * 48_000))
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
        let compressed = AVAudioCompressedBuffer(format: outputFormat, packetCapacity: 1, maximumPacketSize: 4096)
        var supplied = false
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
        guard status != .error, compressed.packetCount > 0, compressed.byteLength > 0 else { return }
        // One AAC access unit is emitted per RTP packet. AVAudioConverter can
        // buffer input; timestamps advance by the AAC-LC frame size on output.
        let data = Data(bytes: compressed.data, count: Int(compressed.byteLength))
        if Int32(bitPattern: timestamp &- nextTimestamp) > 1024 { nextTimestamp = timestamp }
        onFrame?(Frame(data: data, timestamp: nextTimestamp))
        nextTimestamp &+= 1024
    }
}
