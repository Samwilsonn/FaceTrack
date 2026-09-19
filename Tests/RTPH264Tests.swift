import Foundation
import XCTest
@testable import FaceTrackCore

final class RTPH264Tests: XCTestCase {
    func testSingleNALHeaderAndSequenceWrap() {
        var sequence = UInt16.max
        let unit = Data([0x65, 0xab, 0xcd])
        let data = RTPH264.packetize(unit, sequence: &sequence, timestamp: 0x12345678,
                                    ssrc: 0xabcdef01, channel: 2, marker: true)
        XCTAssertEqual(Array(data.prefix(16)), [0x24, 2, 0, 15, 0x80, 0xe0, 0xff, 0xff,
                                               0x12, 0x34, 0x56, 0x78, 0xab, 0xcd, 0xef, 1])
        XCTAssertEqual(Data(data.dropFirst(16)), unit)
        XCTAssertEqual(sequence, 0)
    }

    func testFragmentationRoundTripsBoundariesAndMarksOnlyLastPacket() throws {
        for size in [1, 1200, 1201, 2397, 2398, 64000] {
            let unit = Data([0x65]) + Data((0..<(size - 1)).map { UInt8(truncatingIfNeeded: $0) })
            var sequence: UInt16 = 65534
            let wire = RTPH264.packetize(unit, sequence: &sequence, timestamp: 90000,
                                        ssrc: 10, channel: 0, marker: true)
            var offset = 0
            var recovered = Data()
            var count = 0
            while offset < wire.count {
                XCTAssertGreaterThanOrEqual(wire.count - offset, 16)
                let length = Int(wire[offset + 2]) * 256 + Int(wire[offset + 3])
                XCTAssertLessThanOrEqual(length, 1212)
                let end = offset + 4 + length
                XCTAssertLessThanOrEqual(end, wire.count)
                guard end <= wire.count else { return XCTFail("Truncated RTP packet") }
                let packet = wire.subdata(in: offset..<end)
                XCTAssertEqual(packet.readBE(at: 8), 90000)
                XCTAssertEqual(packet.readBE(at: 12), 10)
                XCTAssertEqual(packet[5] & 0x80 != 0, end == wire.count)
                XCTAssertEqual(UInt16(packet[6]) << 8 | UInt16(packet[7]), UInt16(65534) &+ UInt16(count))
                let payload = packet.dropFirst(16)
                if size <= 1200 {
                    recovered.append(contentsOf: payload)
                } else {
                    let bytes = Array(payload)
                    XCTAssertEqual(bytes[0] & 31, 28)
                    XCTAssertEqual(bytes[1] & 0x80 != 0, count == 0)
                    XCTAssertEqual(bytes[1] & 0x40 != 0, end == wire.count)
                    if count == 0 { recovered.append((bytes[0] & 0xe0) | (bytes[1] & 31)) }
                    recovered.append(contentsOf: bytes.dropFirst(2))
                }
                count += 1; offset = end
            }
            XCTAssertEqual(recovered, unit)
            XCTAssertEqual(sequence, UInt16(65534) &+ UInt16(count))
        }
    }

    func testParameterSetsDoNotEndAccessUnitAndEmptyNALUsesNoSequence() {
        var sequence: UInt16 = 7
        let empty = RTPH264.packetize(Data(), sequence: &sequence, timestamp: 0, ssrc: 1, channel: 0, marker: true)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(sequence, 7)
        let sps = RTPH264.packetize(Data([0x67, 1, 2, 3]), sequence: &sequence, timestamp: 0, ssrc: 1, channel: 0, marker: false)
        XCTAssertEqual(sps[5], 96)
        XCTAssertEqual(sequence, 8)
    }
}
