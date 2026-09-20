import XCTest
@testable import FaceTrackCore

final class VideoStreamDescriptionTests: XCTestCase {
    func testVideoAndAudioAreAdvertised() {
        let control = "rtsp://127.0.0.1:8554/facepull/trackID=0?token=test"
        let sdp = VideoStreamDescription.sdp(control: control)
        XCTAssertEqual(sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("m=") },
                       ["m=video 0 RTP/AVP 96", "m=audio 0 RTP/AVP 97"])
        XCTAssertTrue(sdp.contains("a=rtpmap:96 H264/90000\r\n"))
        XCTAssertTrue(sdp.contains("a=control:\(control)\r\n"))
        XCTAssertTrue(sdp.contains("MPEG4-GENERIC/48000/1"))
        XCTAssertTrue(sdp.contains("trackID=1"))
    }

    func testFormerAudioTrackIsNotAccepted() {
        XCTAssertTrue(VideoStreamDescription.accepts(path: "/facepull"))
        XCTAssertTrue(VideoStreamDescription.accepts(path: "/facepull/trackID=0"))
        XCTAssertTrue(VideoStreamDescription.accepts(path: "/facepull/trackID=1"))
        XCTAssertFalse(VideoStreamDescription.accepts(path: "/facepull/trackID=2"))
    }

    func testDescriptionUsesActualEncoderHeadersAndFrameRate() throws {
        let sps = Data([0x67, 0x64, 0x00, 0x28, 0xac])
        let pps = Data([0x68, 0xee, 0x3c, 0x80])
        let format = try XCTUnwrap(VideoStreamDescription.Format(units: [sps, pps, Data([0x65, 1])]))
        let sdp = VideoStreamDescription.sdp(control: "rtsp://host/facepull/trackID=0?token=test", frameRate: 24, format: format)
        XCTAssertTrue(sdp.contains("profile-level-id=640028"))
        XCTAssertTrue(sdp.contains("sprop-parameter-sets=\(sps.base64EncodedString()),\(pps.base64EncodedString())\r\n"))
        XCTAssertTrue(sdp.contains("a=framerate:24\r\n"))
        XCTAssertTrue(sdp.contains("c=IN IP4 0.0.0.0\r\n"))
        XCTAssertFalse(sdp.contains("m=audio"))
    }

    func testMissingOrMalformedHeadersUseCompatibleInBandFallback() {
        XCTAssertNil(VideoStreamDescription.Format(units: [Data([0x65, 1])]))
        XCTAssertNil(VideoStreamDescription.Format(units: [Data([0x67, 1]), Data([0x68, 1])]))
        XCTAssertNil(VideoStreamDescription.Format(units: [Data([0x67, 0x64, 0, 0x28])]))
        let sdp = VideoStreamDescription.sdp(control: "rtsp://host/facepull/trackID=0?token=test")
        XCTAssertFalse(sdp.contains("sprop-parameter-sets="))
        XCTAssertTrue(sdp.contains("a=framerate:30\r\n"))
    }

    func testTrackURLPreservesQueryOrderAndEscaping() throws {
        let uri = "rtsp://127.0.0.1:8554/facepull?client=obs&token=a%2Bb"
        let track = try XCTUnwrap(VideoStreamDescription.videoControlURL(uri))
        let url = try XCTUnwrap(URLComponents(string: track))
        XCTAssertEqual(url.path, "/facepull/trackID=0")
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "token" })?.value, "a+b")
        XCTAssertEqual(url.queryItems?.first(where: { $0.name == "client" })?.value, "obs")
        XCTAssertNil(VideoStreamDescription.videoControlURL("rtsp://host/other?token=test"))
    }
}
