import Foundation

/// A small flight window, not a playback queue. The transport owns synchronization.
struct PreviewSendWindow {
    static let capacity = 4
    static let deadline: TimeInterval = 0.25
    private(set) var pending: [UInt32: TimeInterval] = [:]
    private(set) var needsKeyframe = true

    mutating func admit(sequence: UInt32, keyframe: Bool, now: TimeInterval) -> Bool {
        guard pending.count < Self.capacity else { needsKeyframe = true; return false }
        guard !needsKeyframe || keyframe else { return false }
        if keyframe { needsKeyframe = false }
        pending[sequence] = now
        return true
    }

    mutating func acknowledge(_ sequence: UInt32, needsKeyframe: Bool) -> Bool {
        guard pending.removeValue(forKey: sequence) != nil else { return false }
        self.needsKeyframe = self.needsKeyframe || needsKeyframe
        return true
    }

    mutating func requireKeyframe() { needsKeyframe = true }
    func expired(now: TimeInterval) -> Bool {
        pending.values.contains { now - $0 >= Self.deadline }
    }
}

/// Socket capacity is adaptive, so pressure is an indicator, not an ACK or a
/// measurement of glass-to-glass latency. Never label contentProcessed as delivery.
struct TCPBacklogGuard {
    var maximumQueuedBytes = 65_536
    private var peakFreeBytes = 0
    private var pressureSince: TimeInterval?
    mutating func observe(freeBytes: Int, now: TimeInterval) -> Bool {
        peakFreeBytes = max(peakFreeBytes, freeBytes)
        if peakFreeBytes - freeBytes >= maximumQueuedBytes || freeBytes < 16_384 {
            if pressureSince == nil { pressureSince = now }
        } else { pressureSince = nil }
        return pressureSince.map { now - $0 >= 0.35 } ?? false
    }
}
