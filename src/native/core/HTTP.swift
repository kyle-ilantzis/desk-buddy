// The little HTTP that sessions speak to the app. Each OS layer owns the transport
// (a Unix socket on macOS, a named pipe on Windows); the requests and replies are the same.
import Foundation

public struct Reply {
    public var status = 200
    public var body: [String: Any] = ["ok": true]
    public var then: (() -> Void)? = nil // runs once the reply has gone

    public init(status: Int = 200, body: [String: Any] = ["ok": true], then: (() -> Void)? = nil) {
        self.status = status
        self.body = body
        self.then = then
    }
}

public enum HTTP {
    /// The reply once the whole request is in `buffer`; nil until then. `route` gets "METHOD /path" and the body.
    public static func reply(to buffer: Data, route: (String, Data) -> Reply) -> Reply? {
        if buffer.count > maxRequest { return Reply(status: 413) }
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let length = lines.dropFirst().compactMap { line -> Int? in
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
            return Int(parts[1].trimmingCharacters(in: .whitespaces))
        }.first ?? 0
        guard buffer.count - end.upperBound >= length else { return nil }
        let start = lines[0].split(separator: " ")
        guard start.count == 3 else { return Reply(status: 400) }
        let path = start[1].split(separator: "?", omittingEmptySubsequences: false)[0]
        return route("\(start[0]) \(path)", Data(buffer[end.upperBound...].prefix(length)))
    }

    /// The reply as bytes, ready to send. The connection closes after it.
    public static func encode(_ reply: Reply) -> Data {
        var body = reply.body
        if reply.status != 200 { body = ["ok": false] }
        let json = (try? JSONSerialization.data(withJSONObject: body, options: [.withoutEscapingSlashes])) ?? Data("{}".utf8)
        let head = "HTTP/1.1 \(reply.status) \(reply.status == 200 ? "OK" : "Error")\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n"
        return Data(head.utf8) + json
    }
}
