import Foundation
import os.signpost

/// Opt-in Instruments events, not production per-frame logging. TCP completion
/// measures local processing, never remote receipt or OBS presentation.
enum StreamDiagnostics {
    private static let enabled = ProcessInfo.processInfo.arguments.contains("--latency-trace")
    private static let log = OSLog(subsystem: "com.anmol.FaceTrackCam", category: .pointsOfInterest)
    static func sample(_ stage: StaticString, milliseconds: Double) {
        guard enabled else { return }
        os_signpost(.event, log: log, name: stage, "ms=%{public}.2f", milliseconds)
    }
}
