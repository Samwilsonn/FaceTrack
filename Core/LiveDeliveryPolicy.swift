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

/// Restore the last-working blocked-send deadline, not a media playback buffer.
/// A successful write clears its start time. Free TCP capacity is deliberately
/// excluded: neither a small buffer nor a changing capacity proves a stall.
enum RTSPSendDeadline {
    static func isExpired(startedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let startedAt else { return false }
        return now - startedAt >= 2
    }
}
