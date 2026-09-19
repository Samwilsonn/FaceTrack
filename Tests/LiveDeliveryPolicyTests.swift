import XCTest
import CoreGraphics
@testable import FaceTrackCore

final class LiveDeliveryPolicyTests: XCTestCase {
    func testFlightWindowAndRecovery() {
        var window = PreviewSendWindow()
        XCTAssertFalse(window.admit(sequence: 0, keyframe: false, now: 0))
        XCTAssertTrue(window.admit(sequence: 1, keyframe: true, now: 0))
        for sequence: UInt32 in 2...4 {
            XCTAssertTrue(window.admit(sequence: sequence, keyframe: false, now: 0.01))
        }
        XCTAssertFalse(window.admit(sequence: 5, keyframe: false, now: 0.02))
        XCTAssertTrue(window.acknowledge(1, needsKeyframe: false))
        XCTAssertFalse(window.admit(sequence: 5, keyframe: false, now: 0.03))
        XCTAssertTrue(window.admit(sequence: 5, keyframe: true, now: 0.03))
        XCTAssertFalse(window.acknowledge(99, needsKeyframe: true))
        XCTAssertFalse(window.expired(now: 0.2))
        XCTAssertTrue(window.expired(now: 0.3))
    }
    func testSocketPressureMustPersist() {
        var guardrail = TCPBacklogGuard()
        XCTAssertFalse(guardrail.observe(freeBytes: 200000, now: 0))
        XCTAssertFalse(guardrail.observe(freeBytes: 100000, now: 1))
        XCTAssertFalse(guardrail.observe(freeBytes: 100000, now: 1.2))
        XCTAssertTrue(guardrail.observe(freeBytes: 100000, now: 1.4))
        XCTAssertFalse(guardrail.observe(freeBytes: 200000, now: 2))
        XCTAssertFalse(guardrail.observe(freeBytes: 100000, now: 3))
    }
    func testPreviewOrientationMatchesHostPolicy() {
        XCTAssertTrue(PreviewGeometry.rotatesToPortrait(source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 390, height: 844)))
        XCTAssertFalse(PreviewGeometry.rotatesToPortrait(source: CGSize(width: 1080, height: 1920), viewport: CGSize(width: 390, height: 844)))
        XCTAssertFalse(PreviewGeometry.rotatesToPortrait(source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 844, height: 390)))
    }
}
