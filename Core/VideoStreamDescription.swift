import Foundation

/// The active stream advertises and accepts exactly one H.264 video track.
enum VideoStreamDescription {
    static func accepts(path: String) -> Bool {
        ["/facepull", "/facepull/trackID=0"].contains(path)
    }

    static func sdp(control: String) -> String {
        "v=0\r\no=FacePull 0 0 IN IP4 127.0.0.1\r\ns=FacePull\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\r\na=control:\(control)\r\n"
    }
}
