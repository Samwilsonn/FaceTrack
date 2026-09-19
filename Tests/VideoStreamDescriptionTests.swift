import XCTest
@testable import FaceTrackCore

final class VideoStreamDescriptionTests: XCTestCase {
    func testOnlyVideoIsAdvertised() {
        let control = "rtsp://127.0.0.1:8554/facepull/trackID=0?token=test"
        let sdp = VideoStreamDescription.sdp(control: control)
        XCTAssertEqual(sdp.components(separatedBy: "\r\n").filter { $0.hasPrefix("m=") },
                       ["m=video 0 RTP/AVP 96"])
        XCTAssertTrue(sdp.contains("a=rtpmap:96 H264/90000\r\n"))
        XCTAssertTrue(sdp.contains("a=control:\(control)\r\n"))
        XCTAssertFalse(sdp.contains("MPEG4-GENERIC"))
        XCTAssertFalse(sdp.contains("trackID=1"))
    }

    func testFormerAudioTrackIsNotAccepted() {
        XCTAssertTrue(VideoStreamDescription.accepts(path: "/facepull"))
        XCTAssertTrue(VideoStreamDescription.accepts(path: "/facepull/trackID=0"))
        XCTAssertFalse(VideoStreamDescription.accepts(path: "/facepull/trackID=1"))
        XCTAssertFalse(VideoStreamDescription.accepts(path: "/facepull/trackID=2"))
    }
}
