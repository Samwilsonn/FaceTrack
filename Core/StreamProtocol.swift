import Foundation

enum HTTPRequestResult: Equatable {
    case incomplete
    case rejected(Int)
    case route(String)
}

enum StreamProtocol {
    static let maximumHeaderBytes = 8192

    static func parse(_ data: Data, token: String, remoteToken: String? = nil) -> HTTPRequestResult {
        guard data.count <= maximumHeaderBytes else { return .rejected(431) }
        let separator = Data("\r\n\r\n".utf8)
        guard let headerEnd = data.range(of: separator) else { return .incomplete }
        let headerData = data[..<headerEnd.lowerBound]
        guard let header = String(data: headerData, encoding: .utf8) else { return .rejected(400) }
        let words = header.components(separatedBy: "\r\n")[0].split(separator: " ")
        guard words.count == 3, words[2] == "HTTP/1.1" || words[2] == "HTTP/1.0" else { return .rejected(400) }
        guard words[1].hasPrefix("/"), !words[1].hasPrefix("//"),
              let url = URLComponents(string: "http://localhost" + words[1]) else { return .rejected(400) }
        let remote = url.path.hasPrefix("/remote")
        if url.path == "/remote", remoteToken != nil, words[0] == "GET" { return .route(url.path) }
        if url.path == "/remote/control" {
            guard words[0] == "POST" else { return .rejected(405) }
        } else if words[0] != "GET" { return .rejected(405) }
        let tokens = url.queryItems?.filter { $0.name == "token" } ?? []
        guard let expected = remote ? remoteToken : token,
              tokens.count == 1, tokens[0].value == expected else { return .rejected(403) }
        guard ["/status", "/remote/state", "/remote/control"].contains(url.path) else { return .rejected(404) }
        if url.path == "/remote/control" {
            let lines = header.components(separatedBy: "\r\n").dropFirst()
            let lengths = lines.filter { $0.lowercased().hasPrefix("content-length:") }
            guard lengths.count == 1, let length = Int(lengths[0].dropFirst(15).trimmingCharacters(in: .whitespaces)),
                  length > 0, length <= 4096,
                  lines.contains(where: { $0.lowercased() == "content-type: application/json" }),
                  !lines.contains(where: { $0.lowercased().hasPrefix("transfer-encoding:") }) else { return .rejected(400) }
            if data.count - headerEnd.upperBound < length { return .incomplete }
            if data.count - headerEnd.upperBound != length { return .rejected(400) }
        }
        return .route(url.path)
    }

    static func response(status: Int = 200, type: String, body: Data) -> Data {
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout", 431: "Request Header Fields Too Large", 503: "Service Unavailable"][status] ?? "Error"
        return Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\nX-Content-Type-Options: nosniff\r\n\r\n".utf8) + body
    }

}

