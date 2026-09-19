import Foundation

/// A small flight window, not a playback queue. The transport owns synchronization.
struct PreviewSendWindow {
    static let capacity = 4
    static let deadline: TimeInterval = 0.25
    static let disconnectDeadline: TimeInterval = 2
    static let byteCapacity = 512 * 1024
    private(set) var pending: [UInt32: TimeInterval] = [:]
    private var sizes: [UInt32: Int] = [:]
    private(set) var pendingBytes = 0
    private(set) var needsKeyframe = true

    mutating func admit(sequence: UInt32, keyframe: Bool, now: TimeInterval, bytes: Int = 0) -> Bool {
        guard bytes >= 0, bytes <= PreviewPacket.maximumBytes else { needsKeyframe = true; return false }
        if expired(now: now) { needsKeyframe = true }
        // Drain the previous reference chain, including its ACKs, before recovery.
        // One large IDR may travel alone; it must not bring a full window behind it.
        if needsKeyframe && !pending.isEmpty { return false }
        guard pending.count < Self.capacity else { needsKeyframe = true; return false }
        guard pendingBytes + bytes <= Self.byteCapacity || (pending.isEmpty && keyframe) else {
            needsKeyframe = true; return false
        }
        guard !needsKeyframe || keyframe else { return false }
        if keyframe { needsKeyframe = false }
        pending[sequence] = now
        sizes[sequence] = bytes; pendingBytes += bytes
        return true
    }

    mutating func acknowledge(_ sequence: UInt32, needsKeyframe: Bool) -> Bool {
        guard pending.removeValue(forKey: sequence) != nil else { return false }
        pendingBytes -= sizes.removeValue(forKey: sequence) ?? 0
        self.needsKeyframe = self.needsKeyframe || needsKeyframe
        return true
    }

    mutating func requireKeyframe() { needsKeyframe = true }
    func expired(now: TimeInterval) -> Bool {
        pending.values.contains { now - $0 >= Self.deadline }
    }
    func stalled(now: TimeInterval) -> Bool {
        pending.values.contains { now - $0 >= Self.disconnectDeadline }
    }
}

/// Cross-device clocks have no known absolute offset. Only a fresh recovery IDR
/// sent after the old flight window drained may re-anchor a modest delay step.
/// An arbitrarily late IDR must not redefine stale video as current.
struct PreviewArrivalClock {
    private var lastTimestamp: UInt32?
    private var earliestOffset: TimeInterval?
    private(set) var elapsed: TimeInterval = 0
    private(set) var drift: TimeInterval = 0

    mutating func accept(timestamp: UInt32, now: TimeInterval, recoveryKeyframe: Bool) -> Bool {
        if let lastTimestamp {
            let delta = Int32(bitPattern: timestamp &- lastTimestamp)
            guard delta > 0 else { return false }
            elapsed += Double(delta) / 90_000
        }
        // Track observed source time even when display is rejected. These deltas
        // telescope to the first-to-current timestamp; dropping an image must
        // not remove its duration or allow subsequent stale frames to catch up.
        lastTimestamp = timestamp
        let offset = now - elapsed
        earliestOffset = min(earliestOffset ?? offset, offset)
        drift = offset - (earliestOffset ?? offset)
        if drift >= 0.12 && recoveryKeyframe && drift < 0.35 {
            earliestOffset = offset
            return true
        }
        return drift < 0.12
    }
}

/// Restore the last-working blocked-send deadline, not a media playback buffer.
/// A successful write clears its start time. Free TCP capacity is deliberately
/// excluded: neither a small buffer nor a changing capacity proves a stall.
enum RTSPSendDeadline {
    static func isExpired(startedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt >= 2
    }
}
