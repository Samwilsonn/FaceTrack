import Foundation

/// The active stream supports H.264 video and optional AAC audio.
enum VideoStreamDescription {
    static func accepts(path: String) -> Bool {
        ["/facepull", "/facepull/trackID=0", "/facepull/trackID=1"].contains(path)
    }

    struct Format: Equatable {
        let sps: Data
        let pps: Data

        init?(units: [Data]) {
            guard let sps = units.first(where: { $0.first.map { $0 & 0x1f == 7 } == true }),
                  let pps = units.first(where: { $0.first.map { $0 & 0x1f == 8 } == true }),
                  sps.count >= 4, pps.count >= 2 else { return nil }
            self.sps = sps; self.pps = pps
        }

        var parameters: String {
            let profile = sps.dropFirst().prefix(3).map { String(format: "%02x", $0) }.joined()
            return "profile-level-id=\(profile);sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())"
        }
    }

    static func videoControlURL(_ uri: String) -> String? {
        guard var url = URLComponents(string: uri), url.path == "/facepull" else { return nil }
        url.path = "/facepull/trackID=0"
        return url.string
    }

    static func sdp(control: String, frameRate: Int = 30, format: Format? = nil, audioControl: String? = nil) -> String {
        let parameters = format.map { ";\($0.parameters)" } ?? ""
        var description = "v=0\r\no=FacePull 0 0 IN IP4 127.0.0.1\r\ns=FacePull\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\nc=IN IP4 0.0.0.0\r\na=rtpmap:96 H264/90000\r\na=fmtp:96 packetization-mode=1\(parameters)\r\na=framerate:\(max(1, frameRate))\r\na=control:\(control)\r\n"
        if let audioControl = audioControl {
            description += "m=audio 0 RTP/AVP 97\r\na=rtpmap:97 MPEG4-GENERIC/48000/1\r\na=fmtp:97 streamtype=5;profile-level-id=1;mode=AAC-hbr;config=1188;constantDuration=1024;SizeLength=13;IndexLength=3;IndexDeltaLength=3\r\na=control:\(audioControl)\r\n"
        }
        return description
    }
}
