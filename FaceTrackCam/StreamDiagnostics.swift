import Foundation
import os.signpost

/// Opt-in Instruments events, not production per-frame logging. TCP completion
/// measures local processing, never remote receipt or OBS presentation.
enum StreamDiagnostics {
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--latency-trace")
    private static let log = OSLog(subsystem: "com.anmol.FaceTrackCam", category: .pointsOfInterest)
    static var isEnabled: Bool { enabled }
    static func sample(_ stage: StaticString, milliseconds: Double) {
        guard enabled else { return }
        os_signpost(.event, log: log, name: stage, "ms=%{public}.2f", milliseconds)
    }

    static func elapsed(_ stage: StaticString, since start: TimeInterval) {
        guard enabled else { return }
        sample(stage, milliseconds: (ProcessInfo.processInfo.systemUptime - start) * 1000)
    }

    static func status(_ stage: StaticString, code: Int32, fallback: Bool = false) {
        guard enabled else { return }
        os_signpost(.event, log: log, name: stage, "status=%{public}d fallback=%{public}d",
                    code, fallback ? Int32(1) : Int32(0))
    }
}
