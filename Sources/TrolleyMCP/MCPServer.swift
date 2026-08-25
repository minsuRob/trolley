import Foundation

public struct ToolDefinition {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    var jsonValue: JSONValue {
        .object([
            "name": .string(name),
            "description": .string(description),
            "inputSchema": inputSchema
        ])
    }
}

/// The set of tools a server exposes. Implemented by `TrolleyTools`; the server
/// itself knows nothing about accessibility.
public protocol ToolProviding {
    var tools: [ToolDefinition] { get }
    /// Throwing `ToolError` produces an `isError: true` result for the model.
    func call(name: String, arguments: JSONValue) throws -> JSONValue
}

/// Newline-delimited JSON-RPC 2.0 over stdio, covering the tools-only slice of
/// MCP. Reading and writing are injected so the whole protocol layer is testable
/// without spawning a process.
public struct MCPServer {
    public static let serverVersion = "0.1.0"
    /// Versions we know how to speak. We echo the client's version when it's one
    /// of these, and otherwise answer with our preferred one.
    static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]
    static let preferredProtocolVersion = "2025-06-18"

    let provider: ToolProviding
    let readLine: () -> String?
    let writeLine: (String) -> Void
    let logLine: (String) -> Void

    public init(
        provider: ToolProviding,
        readLine: @escaping () -> String? = { Swift.readLine(strippingNewline: true) },
        writeLine: @escaping (String) -> Void = { line in
            print(line)
            fflush(stdout)
        },
        logLine: @escaping (String) -> Void = { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
    ) {
        self.provider = provider
        self.readLine = readLine
        self.writeLine = writeLine
        self.logLine = logLine
    }

    /// Blocks until stdin reaches EOF, which is how MCP clients shut a stdio
    /// server down. One request is handled at a time, on this thread -- AX calls
    /// are synchronous and not thread-safe, so serial execution is the point.
    public func run() {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if let response = handle(line: trimmed) {
                emit(response)
            }
        }
    }

    func emit(_ response: RPCResponse) {
        do {
            writeLine(try response.jsonValue().serializedLine())
        } catch {
            logLine("failed to encode response: \(error)")
        }
    }

    /// Returns nil for notifications, which JSON-RPC forbids answering.
    func handle(line: String) -> RPCResponse? {
        let request: RPCRequest
        do {
            request = try JSONDecoder().decode(RPCRequest.self, from: Data(line.utf8))
        } catch {
            logLine("parse error: \(error)")
            return .failure(id: nil, code: .parseError, message: "invalid JSON-RPC message")
        }

        switch request.method {
        case "initialize":
            guard let id = request.id else { return nil }
            return .result(id: id, value: initializeResult(params: request.params))

        case "ping":
            guard let id = request.id else { return nil }
            return .result(id: id, value: .object([:]))

        case "tools/list":
            guard let id = request.id else { return nil }
            return .result(id: id, value: .object([
                "tools": .array(provider.tools.map(\.jsonValue))
            ]))

        case "tools/call":
            guard let id = request.id else { return nil }
            return toolCallResult(id: id, params: request.params)

        default:
            // Unknown notifications (notifications/initialized, cancellations,
            // etc.) are ignored by design.
            guard let id = request.id else { return nil }
            return .failure(id: id, code: .methodNotFound, message: "unknown method \"\(request.method)\"")
        }
    }

    private func initializeResult(params: JSONValue?) -> JSONValue {
        let requested = params?["protocolVersion"]?.stringValue
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.preferredProtocolVersion
        return .object([
            "protocolVersion": .string(version),
            "capabilities": .object(["tools": .object([:])]),
            "serverInfo": .object([
                "name": .string("trolley"),
                "version": .string(Self.serverVersion)
            ])
        ])
    }

    private func toolCallResult(id: RequestID, params: JSONValue?) -> RPCResponse {
        guard let name = params?["name"]?.stringValue else {
            return .failure(id: id, code: .invalidParams, message: "tools/call requires a \"name\"")
        }
        let arguments = params?["arguments"] ?? .object([:])

        do {
            let value = try provider.call(name: name, arguments: arguments)
            return .result(id: id, value: Self.toolContent(value, isError: false))
        } catch let error as ToolError {
            logLine("tool \(name) failed: \(error.code.rawValue) \(error.message)")
            return .result(id: id, value: Self.toolContent(error.jsonValue, isError: true))
        } catch {
            logLine("tool \(name) threw: \(error)")
            let fallback = ToolError(.actionFailed, "\(error)")
            return .result(id: id, value: Self.toolContent(fallback.jsonValue, isError: true))
        }
    }

    /// Tool payloads travel as a JSON document inside a text content block --
    /// that is what MCP's content model allows, and it keeps the result readable
    /// to the model.
    static func toolContent(_ value: JSONValue, isError: Bool) -> JSONValue {
        let text = (try? value.prettyPrinted()) ?? "{\"error\":{\"code\":\"ACTION_FAILED\",\"message\":\"result was not encodable\"}}"
        return .object([
            "content": .array([
                .object(["type": .string("text"), "text": .string(text)])
            ]),
            "isError": .bool(isError)
        ])
    }
}
