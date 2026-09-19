import Foundation

/// RFC 6184 single NAL/FU-A packets, interleaved on the negotiated RTSP channel.
enum RTPH264 {
    static func packetize(_ unit: Data, sequence: inout UInt16, timestamp: UInt32,
                          ssrc: UInt32, channel: UInt8, marker: Bool) -> Data {
        guard let first = unit.first else { return Data() }
        let bytes = [UInt8](unit)
        let payloadSize = 1200
        var output = Data()
        if bytes.count <= payloadSize {
            output.append(packet(Data(bytes), sequence: &sequence, timestamp: timestamp, ssrc: ssrc, channel: channel, marker: marker))
        } else {
            let indicator = (first & 0xe0) | 28
            let kind = first & 0x1f
            var offset = 1
            while offset < bytes.count {
                let count = min(payloadSize - 2, bytes.count - offset)
                let start = offset == 1, end = offset + count == bytes.count
                var fragment = Data([indicator, kind | (start ? 0x80 : 0) | (end ? 0x40 : 0)])
                fragment.append(contentsOf: bytes[offset..<(offset + count)])
                output.append(packet(fragment, sequence: &sequence, timestamp: timestamp, ssrc: ssrc, channel: channel, marker: marker && end))
                offset += count
            }
        }
        return output
    }

    private static func packet(_ payload: Data, sequence: inout UInt16, timestamp: UInt32,
                               ssrc: UInt32, channel: UInt8, marker: Bool) -> Data {
        let length = payload.count + 12
        var result = Data([0x24, channel, UInt8(length >> 8), UInt8(length & 0xff),
                           0x80, marker ? 0xe0 : 0x60,
                           UInt8(sequence >> 8), UInt8(sequence & 0xff),
                           UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
                           UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff),
                           UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xff),
                           UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff)])
        result.append(payload)
        sequence &+= 1
        return result
    }
}
