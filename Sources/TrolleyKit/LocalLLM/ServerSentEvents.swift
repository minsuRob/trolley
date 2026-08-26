import Foundation

/// One dispatched `text/event-stream` frame.
public struct SSEFrame: Equatable {
    /// Defaults to `message` per the spec; this server always names its events.
    public let event: String
    public let data: String

    public init(event: String, data: String) {
        self.event = event
        self.data = data
    }
}

/// Line-at-a-time SSE decoder.
///
/// Split out from the client so the awkward parts are testable without a
/// server: the blank line is the dispatch (not the newline after `data:`),
/// a line starting with `:` is a comment -- which is exactly what this server
/// sends as its 30-second keepalive -- and a frame with no data is never
/// dispatched at all.
public struct SSELineParser {
    private var event: String?
    private var dataLines: [String] = []

    public init() {}

    /// - Returns: the completed frame when `line` was the blank line that ends
    ///   one, otherwise nil.
    public mutating func feed(_ line: String) -> SSEFrame? {
        // Servers may send CRLF; the CR is not part of the value.
        let line = line.hasSuffix("\r") ? String(line.dropLast()) : line

        if line.isEmpty {
            defer {
                event = nil
                dataLines = []
            }
            guard !dataLines.isEmpty else { return nil }
            return SSEFrame(event: event ?? "message", data: dataLines.joined(separator: "\n"))
        }
        if line.hasPrefix(":") { return nil }

        let (field, rawValue): (String, String)
        if let colon = line.firstIndex(of: ":") {
            field = String(line[line.startIndex..<colon])
            rawValue = String(line[line.index(after: colon)...])
        } else {
            field = line
            rawValue = ""
        }
        // A single leading space after the colon is separator, not content.
        let value = rawValue.hasPrefix(" ") ? String(rawValue.dropFirst()) : rawValue

        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        default: break   // id / retry / anything unknown: not used here
        }
        return nil
    }
}
