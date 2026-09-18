import Foundation

enum LiveStreamClock {
    static func ticks(_ seconds: Double, rate: Double) -> UInt32 {
        UInt32(truncatingIfNeeded: Int64((seconds * rate).rounded()))
    }

    // Compound RTCP SR + SDES, with the same CNAME and NTP clock for both tracks.
    static func report(channel: UInt8, ssrc: UInt32, timestamp: UInt32,
                       unixTime: Double, packets: UInt32, octets: UInt32) -> Data {
        let ntp = unixTime + 2_208_988_800
        var body = Data([0x80, 200, 0, 6])
        for value in [ssrc, UInt32(truncatingIfNeeded: UInt64(ntp)),
                      UInt32((ntp - floor(ntp)) * 4_294_967_296), timestamp, packets, octets] {
            body.appendBE(value)
        }
        let cname = Data("FacePull".utf8)
        var sdes = Data([0x81, 202, 0, 0])
        sdes.appendBE(ssrc)
        sdes.append(contentsOf: [1, UInt8(cname.count)])
        sdes.append(cname); sdes.append(0)
        while sdes.count % 4 != 0 { sdes.append(0) }
        let words = sdes.count / 4 - 1
        sdes[2] = UInt8(words >> 8); sdes[3] = UInt8(words & 255)
        body.append(sdes)
        var result = Data([0x24, channel, UInt8(body.count >> 8), UInt8(body.count & 255)])
        result.append(body)
        return result
    }
}

struct PreviewPacket {
    static let maximumBytes = 4 * 1024 * 1024
    let sequence: UInt32
    let timestamp: UInt32
    let keyframe: Bool
    let units: [Data]

    func encoded() -> Data? {
        guard !units.isEmpty, units.count <= 256, units.allSatisfy({ !$0.isEmpty }),
              units.reduce(14, { $0 + 4 + $1.count }) <= Self.maximumBytes else { return nil }
        var data = Data([0x46, 0x50, 1, keyframe ? 1 : 0])
        data.appendBE(sequence); data.appendBE(timestamp)
        data.append(contentsOf: [UInt8(units.count >> 8), UInt8(units.count & 255)])
        for unit in units { data.appendBE(UInt32(unit.count)); data.append(unit) }
        return data
    }

    static func decode(_ data: Data) -> PreviewPacket? {
        guard data.count >= 14, data.count <= maximumBytes,
              data[0] == 0x46, data[1] == 0x50, data[2] == 1, data[3] <= 1 else { return nil }
        let count = Int(data[12]) << 8 | Int(data[13])
        guard count > 0, count <= 256 else { return nil }
        var offset = 14
        var units: [Data] = []
        for _ in 0..<count {
            guard offset + 4 <= data.count else { return nil }
            let size = Int(data.readBE(at: offset)); offset += 4
            guard size > 0, size <= data.count - offset else { return nil }
            units.append(data.subdata(in: offset..<(offset + size))); offset += size
        }
        guard offset == data.count else { return nil }
        return PreviewPacket(sequence: data.readBE(at: 4), timestamp: data.readBE(at: 8),
                             keyframe: data[3] == 1, units: units)
    }

    static func acknowledgement(_ sequence: UInt32, needsKeyframe: Bool) -> Data {
        var data = Data([0x46, 0x41, 1, needsKeyframe ? 1 : 0])
        data.appendBE(sequence)
        return data
    }
}

extension Data {
    mutating func appendBE(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24), UInt8((value >> 16) & 255),
                            UInt8((value >> 8) & 255), UInt8(value & 255)])
    }

    func readBE(at index: Int) -> UInt32 {
        UInt32(self[index]) << 24 | UInt32(self[index + 1]) << 16 |
            UInt32(self[index + 2]) << 8 | UInt32(self[index + 3])
    }
}
