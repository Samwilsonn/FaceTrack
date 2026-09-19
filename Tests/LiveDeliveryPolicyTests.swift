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
        XCTAssertFalse(window.admit(sequence: 5, keyframe: true, now: 0.03))
        for sequence: UInt32 in 2...4 {
            XCTAssertTrue(window.acknowledge(sequence, needsKeyframe: false))
        }
        XCTAssertTrue(window.admit(sequence: 5, keyframe: true, now: 0.04))
        XCTAssertFalse(window.acknowledge(99, needsKeyframe: true))
        XCTAssertFalse(window.expired(now: 0.2))
        XCTAssertTrue(window.expired(now: 0.3))
        XCTAssertFalse(window.stalled(now: 0.3))
        XCTAssertTrue(window.stalled(now: 2.1))
    }
    func testPreviewByteBudgetAndLargeKeyframeTravelsAlone() {
        var window = PreviewSendWindow()
        let size = PreviewSendWindow.byteCapacity + 1
        XCTAssertTrue(window.admit(sequence: 1, keyframe: true, now: 0, bytes: size))
        XCTAssertEqual(window.pendingBytes, size)
        XCTAssertFalse(window.admit(sequence: 2, keyframe: false, now: 0.01, bytes: 1))
        XCTAssertTrue(window.acknowledge(1, needsKeyframe: false))
        XCTAssertEqual(window.pendingBytes, 0)
        XCTAssertTrue(window.admit(sequence: 3, keyframe: true, now: 0.02, bytes: 100))
        XCTAssertFalse(window.acknowledge(1, needsKeyframe: true))
        XCTAssertFalse(window.needsKeyframe)
        XCTAssertFalse(window.admit(sequence: 4, keyframe: true, now: 0.03,
                                    bytes: PreviewPacket.maximumBytes + 1))
    }
    func testSoftDeadlineDrainsWithoutDisconnectOrAdmittingDependentFrames() {
        var window = PreviewSendWindow()
        XCTAssertTrue(window.admit(sequence: 1, keyframe: true, now: 0))
        XCTAssertFalse(window.admit(sequence: 2, keyframe: false, now: 0.3))
        XCTAssertFalse(window.stalled(now: 0.3))
        XCTAssertTrue(window.acknowledge(1, needsKeyframe: true))
        XCTAssertFalse(window.admit(sequence: 2, keyframe: false, now: 0.31))
        XCTAssertTrue(window.admit(sequence: 3, keyframe: true, now: 0.32))
        XCTAssertFalse(window.acknowledge(1, needsKeyframe: true))
        XCTAssertFalse(window.needsKeyframe)
    }
    func testArrivalDelayStepRequiresFreshRecoveryKeyframe() {
        var clock = PreviewArrivalClock()
        XCTAssertTrue(clock.accept(timestamp: 0, now: 10, recoveryKeyframe: false))
        XCTAssertFalse(clock.accept(timestamp: 9_000, now: 10.3, recoveryKeyframe: false))
        // Even an ordinary queued IDR cannot reset the clock. The transport marks
        // recovery only after the previous flight window has drained.
        XCTAssertFalse(clock.accept(timestamp: 18_000, now: 10.4, recoveryKeyframe: false))
        XCTAssertTrue(clock.accept(timestamp: 90_000, now: 11.2, recoveryKeyframe: true))
        XCTAssertTrue(clock.accept(timestamp: 99_000, now: 11.3, recoveryKeyframe: false))
    }
    func testArrivalClockRejectsVeryLateRecoveryAndDuplicateTimestamp() {
        var clock = PreviewArrivalClock()
        XCTAssertTrue(clock.accept(timestamp: 0, now: 10, recoveryKeyframe: false))
        XCTAssertFalse(clock.accept(timestamp: 90_000, now: 12, recoveryKeyframe: true))
        XCTAssertFalse(clock.accept(timestamp: 90_000, now: 12.1, recoveryKeyframe: true))
        XCTAssertFalse(clock.accept(timestamp: 180_000, now: 13, recoveryKeyframe: true))
        XCTAssertTrue(clock.accept(timestamp: 270_000, now: 13.05, recoveryKeyframe: true))
    }
    func testArrivalClockHandlesTimestampWrap() {
        var clock = PreviewArrivalClock()
        let first = UInt32.max - 4_499
        XCTAssertTrue(clock.accept(timestamp: first, now: 1, recoveryKeyframe: false))
        XCTAssertTrue(clock.accept(timestamp: first &+ 9_000, now: 1.1, recoveryKeyframe: false))
        XCTAssertEqual(clock.elapsed, 0.1, accuracy: 0.000001)
    }
    func testStartupWriteIsNotKilledAtOld350msDeadline() {
        XCTAssertFalse(RTSPSendDeadline.isExpired(startedAt: 10, now: 10.35))
        XCTAssertFalse(RTSPSendDeadline.isExpired(startedAt: 10, now: 11.99))
        XCTAssertTrue(RTSPSendDeadline.isExpired(startedAt: 10, now: 12))
    }
    func testCompletedWritesAndIndependentAudioVideoDeadlines() {
        XCTAssertFalse(RTSPSendDeadline.isExpired(startedAt: nil, now: 100))
        // Audio progress cannot hide a blocked video write (or vice versa).
        XCTAssertTrue(RTSPSendDeadline.isExpired(startedAt: 10, now: 12.1))
        XCTAssertFalse(RTSPSendDeadline.isExpired(startedAt: 12, now: 12.1))
    }
    func testPreviewOrientationMatchesHostPolicy() {
        XCTAssertTrue(PreviewGeometry.rotatesToPortrait(source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 390, height: 844)))
        XCTAssertFalse(PreviewGeometry.rotatesToPortrait(source: CGSize(width: 1080, height: 1920), viewport: CGSize(width: 390, height: 844)))
        XCTAssertFalse(PreviewGeometry.rotatesToPortrait(source: CGSize(width: 1920, height: 1080), viewport: CGSize(width: 844, height: 390)))
    }
}
