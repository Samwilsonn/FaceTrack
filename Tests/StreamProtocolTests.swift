import XCTest
@testable import FaceTrackCore

final class StreamProtocolTests: XCTestCase {
    private func parse(_ request: String) -> HTTPRequestResult { StreamProtocol.parse(Data(request.utf8), token: "secret") }
    func testFragmentedRequestWaitsForHeaderTerminator() {
        XCTAssertEqual(parse("GET /status?token=secret HTTP/1.1\r\nHost: phone\r\n"), .incomplete)
        XCTAssertEqual(parse("GET /status?token=secret HTTP/1.1\r\nHost: phone\r\n\r\n"), .route("/status"))
    }
    func testAllRoutesRequireCurrentToken() {
        for route in ["/status"] {
            XCTAssertEqual(parse("GET \(route) HTTP/1.1\r\n\r\n"), .rejected(403))
            XCTAssertEqual(parse("GET \(route)?token=old HTTP/1.1\r\n\r\n"), .rejected(403))
            XCTAssertEqual(parse("GET \(route)?token=secret HTTP/1.1\r\n\r\n"), .route(route))
        }
    }
    func testRejectsDuplicateTokensAndUnknownRoutes() {
        XCTAssertEqual(parse("GET /status?token=wrong&token=secret HTTP/1.1\r\n\r\n"), .rejected(403))
        XCTAssertEqual(parse("GET /missing?token=secret HTTP/1.1\r\n\r\n"), .rejected(404))
        XCTAssertEqual(parse("GET /stream.mjpg?token=secret HTTP/1.1\r\n\r\n"), .rejected(404))
    }
    func testRejectsMalformedAndOversizedRequests() {
        XCTAssertEqual(parse("POST /status?token=secret HTTP/1.1\r\n\r\n"), .rejected(405))
        XCTAssertEqual(parse("garbage\r\n\r\n"), .rejected(400))
        XCTAssertEqual(parse("GET //evil/status?token=secret HTTP/1.1\r\n\r\n"), .rejected(400))
        XCTAssertEqual(parse(String(repeating: "x", count: 8193)), .rejected(431))
    }
    func testRemoteCredentialsAndFragmentedCommands() {
        func remote(_ request: String) -> HTTPRequestResult {
            StreamProtocol.parse(Data(request.utf8), token: "video", remoteToken: "control")
        }
        XCTAssertEqual(remote("GET /remote HTTP/1.1\r\n\r\n"), .route("/remote"))
        XCTAssertEqual(remote("GET /remote/state?token=video HTTP/1.1\r\n\r\n"), .rejected(403))
        XCTAssertEqual(remote("GET /remote/state?token=control HTTP/1.1\r\n\r\n"), .route("/remote/state"))
        XCTAssertEqual(remote("GET /remote/control?token=control HTTP/1.1\r\n\r\n"), .rejected(405))
        let header = "POST /remote/control?token=control HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n"
        XCTAssertEqual(remote(header + "{"), .incomplete)
        XCTAssertEqual(remote(header + "{}"), .route("/remote/control"))
        XCTAssertEqual(remote(header + "{}extra"), .rejected(400))
        XCTAssertEqual(StreamProtocol.parse(Data("GET /remote/state?token HTTP/1.1\r\n\r\n".utf8), token: "video"), .rejected(403))
    }
    func testFragmentedUTF8CommandBodyWaitsForCompleteBytes() {
        let header = "POST /remote/control?token=control HTTP/1.1\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n"
        var first = Data(header.utf8)
        first.append(0xc3)
        XCTAssertEqual(StreamProtocol.parse(first, token: "video", remoteToken: "control"), .incomplete)
        first.append(0xa9)
        XCTAssertEqual(StreamProtocol.parse(first, token: "video", remoteToken: "control"), .route("/remote/control"))
    }
    func testHTTPContentLengthCountsUTF8Bytes() {
        let data = StreamProtocol.response(type: "text/plain", body: Data("✓".utf8))
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("Content-Length: 3\r\n"))
    }
}

