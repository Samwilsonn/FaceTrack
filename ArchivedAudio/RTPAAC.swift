import Foundation

enum RTPAAC {
    static func packetize(_ accessUnit: Data, sequence: inout UInt16, timestamp: UInt32,
                          ssrc: UInt32, channel: UInt8) -> Data {
        // RFC 3640: one AAC-hbr access unit, 16-bit AU-header-length and
        // 13-bit AU-size followed by a zero AU-index.
        let size = accessUnit.count
        let length = size + 16
        var packet = Data([0x24, channel, UInt8(length >> 8), UInt8(length & 0xff)])
        packet.append(contentsOf: [0x80, 0xe1, UInt8(sequence >> 8), UInt8(sequence & 0xff)])
        packet.append(contentsOf: [UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff),
                                   UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff)])
        packet.append(contentsOf: [UInt8(ssrc >> 24), UInt8((ssrc >> 16) & 0xff),
                                   UInt8((ssrc >> 8) & 0xff), UInt8(ssrc & 0xff)])
        packet.append(contentsOf: [0, 16, UInt8(size >> 5), UInt8((size & 0x1f) << 3)])
        packet.append(accessUnit)
        sequence &+= 1
        return packet
    }
}
