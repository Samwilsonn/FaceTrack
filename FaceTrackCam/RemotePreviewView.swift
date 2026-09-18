import AVFoundation
import SwiftUI
import UIKit

final class RemotePreviewModel: ObservableObject {
    @Published private(set) var status = "Preview off"
    let decoder = RemotePreviewDecoder()
    private let channel = RemotePreviewChannel(host: false)
    private var configuration = ""

    init() {
        channel.onPacket = { [weak self] packet in self?.decoder.display(packet) ?? false }
        channel.onStatus = { [weak self] message in
            DispatchQueue.main.async { self?.status = message }
        }
    }

    func configure(enabled: Bool, host: String, token: String, streaming: Bool) {
        let next = enabled && streaming && !host.isEmpty && !token.isEmpty ? host + token : ""
        guard next != configuration else { return }
        configuration = next
        decoder.setEnabled(!next.isEmpty)
        if next.isEmpty { channel.stop(); status = enabled ? "Waiting for Host stream…" : "Preview off" }
        else { channel.start(token: token, target: host) }
    }

    func stop() {
        configuration = ""; channel.stop(); decoder.setEnabled(false); status = "Preview off"
    }
    deinit { channel.stop(); decoder.setEnabled(false) }
}

final class RemotePreviewDecoder {
    private let lock = NSLock()
    private var renderer: AVSampleBufferVideoRenderer?
    private var format: CMVideoFormatDescription?
    private var enabled = false
    private var needsKeyframe = true
    private var lastSequence: UInt32?

    func attach(_ renderer: AVSampleBufferVideoRenderer?) {
        lock.lock(); defer { lock.unlock() }
        self.renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
        self.renderer = renderer; format = nil; needsKeyframe = true; lastSequence = nil
    }

    func setEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        self.enabled = enabled; format = nil; needsKeyframe = true; lastSequence = nil
        renderer?.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func display(_ packet: PreviewPacket) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard enabled, let renderer else { return false }
        if let lastSequence, packet.sequence != lastSequence &+ 1 { needsKeyframe = true }
        lastSequence = packet.sequence
        if renderer.requiresFlushToResumeDecoding || !renderer.isReadyForMoreMediaData {
            renderer.flush(removingDisplayedImage: false, completionHandler: nil)
            needsKeyframe = true
        }
        guard !needsKeyframe || packet.keyframe else { return false }
        if packet.keyframe {
            guard let sps = packet.units.first(where: { ($0.first ?? 0) & 31 == 7 }),
                  let pps = packet.units.first(where: { ($0.first ?? 0) & 31 == 8 }) else { return false }
            var updated: CMFormatDescription?
            let result = sps.withUnsafeBytes { spsBytes in
                pps.withUnsafeBytes { ppsBytes in
                    let pointers = [spsBytes.bindMemory(to: UInt8.self).baseAddress!,
                                    ppsBytes.bindMemory(to: UInt8.self).baseAddress!]
                    let sizes = [sps.count, pps.count]
                    return CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault,
                        parameterSetCount: 2, parameterSetPointers: pointers, parameterSetSizes: sizes,
                        nalUnitHeaderLength: 4, formatDescriptionOut: &updated)
                }
            }
            guard result == noErr, let updated else { return false }
            format = updated; needsKeyframe = false
        }
        guard let format, renderer.isReadyForMoreMediaData else { needsKeyframe = true; return false }
        var avcc = Data()
        for unit in packet.units where (unit.first ?? 0) & 31 != 7 && (unit.first ?? 0) & 31 != 8 {
            avcc.appendBE(UInt32(unit.count)); avcc.append(unit)
        }
        guard !avcc.isEmpty else { return false }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
            blockLength: avcc.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block) == noErr,
            let block else { return false }
        let copied = avcc.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == noErr else { return false }
        var sample: CMSampleBuffer?
        var size = avcc.count
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(packet.timestamp), timescale: 90_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { return false }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(sample)
        return true
    }
}

private final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

struct RemotePreviewView: UIViewRepresentable {
    let decoder: RemotePreviewDecoder
    func makeCoordinator() -> RemotePreviewDecoder { decoder }
    func makeUIView(context: Context) -> UIView {
        let view = PreviewSurface()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspect
        decoder.attach(view.displayLayer.sampleBufferRenderer)
        return view
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    static func dismantleUIView(_ uiView: UIView, coordinator: RemotePreviewDecoder) {
        coordinator.attach(nil)
    }
}
