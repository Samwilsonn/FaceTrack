import Foundation
import XCTest
@testable import FaceTrackCore

final class LiveStreamProtocolTests: XCTestCase {
    func testPreviewRoundTripAndAcknowledgement() throws {
        let packet = PreviewPacket(sequence: .max, timestamp: 123456, keyframe: true,
                                   units: [Data([0x67, 1]), Data([0x68, 2]), Data([0x65, 3, 4])])
        let wire = try XCTUnwrap(packet.encoded())
        let decoded = try XCTUnwrap(PreviewPacket.decode(wire))
        XCTAssertEqual(decoded.sequence, packet.sequence)
        XCTAssertEqual(decoded.timestamp, packet.timestamp)
        XCTAssertTrue(decoded.keyframe)
        XCTAssertEqual(decoded.units, packet.units)
        let ack = PreviewPacket.acknowledgement(.max, needsKeyframe: true)
        XCTAssertEqual(ack.count, 8)
        XCTAssertEqual(Array(ack.prefix(4)), [0x46, 0x41, 1, 1])
        XCTAssertEqual(ack.readBE(at: 4), .max)
    }

    func testPreviewRejectsMalformedAndOversizedPackets() throws {
        let wire = try XCTUnwrap(PreviewPacket(sequence: 1, timestamp: 2, keyframe: false,
                                             units: [Data([0x41, 1])]).encoded())
        for length in 0..<wire.count { XCTAssertNil(PreviewPacket.decode(Data(wire.prefix(length)))) }
        var extra = wire; extra.append(0)
        XCTAssertNil(PreviewPacket.decode(extra))
        var badLength = wire; badLength.replaceSubrange(14..<18, with: [255, 255, 255, 255])
        XCTAssertNil(PreviewPacket.decode(badLength))
        var badVersion = wire; badVersion[2] = 2
        XCTAssertNil(PreviewPacket.decode(badVersion))
        XCTAssertNil(PreviewPacket(sequence: 0, timestamp: 0, keyframe: false, units: []).encoded())
        XCTAssertNil(PreviewPacket(sequence: 0, timestamp: 0, keyframe: false, units: [Data()]).encoded())
        XCTAssertNil(PreviewPacket(sequence: 0, timestamp: 0, keyframe: false,
                                   units: [Data(repeating: 1, count: PreviewPacket.maximumBytes)]).encoded())
    }

    func testAudioVideoReportsShareWallClockAndCNAME() {
        let video = LiveStreamClock.report(channel: 1, ssrc: 10, timestamp: 90000,
                                           unixTime: 1000.5, packets: 2, octets: 100)
        let audio = LiveStreamClock.report(channel: 3, ssrc: 20, timestamp: 48000,
                                           unixTime: 1000.5, packets: 4, octets: 200)
        XCTAssertEqual(video.count, 52)
        XCTAssertEqual(Array(video.prefix(8)), [0x24, 1, 0, 48, 0x80, 200, 0, 6])
        XCTAssertEqual(video.readBE(at: 8), 10)
        XCTAssertEqual(video.readBE(at: 12), 2_208_989_800)
        XCTAssertEqual(video.readBE(at: 16), 0x80000000)
        XCTAssertEqual(video.subdata(in: 12..<20), audio.subdata(in: 12..<20))
        XCTAssertEqual(video.readBE(at: 20), 90000)
        XCTAssertEqual(audio.readBE(at: 20), 48000)
        XCTAssertEqual(video.readBE(at: 24), 2)
        XCTAssertEqual(video.readBE(at: 28), 100)
        XCTAssertEqual(Array(video[32..<36]), [0x81, 202, 0, 4])
        XCTAssertEqual(video.subdata(in: 40..<52), audio.subdata(in: 40..<52))
    }

    func testClockRatesAndRollover() {
        XCTAssertEqual(LiveStreamClock.ticks(1.5, rate: 90000), 135000)
        XCTAssertEqual(LiveStreamClock.ticks(1.5, rate: 48000), 72000)
        XCTAssertEqual(LiveStreamClock.ticks(4_294_967_296.0 / 48000, rate: 48000), 0)
    }
}
