import XCTest
@testable import TrolleyMCP

final class MCPServerTests: XCTestCase {
    /// Drives a server over an in-memory transport and returns everything it wrote.
    private func exchange(_ lines: [String], provider: ToolProviding = StubToolProvider()) -> [JSONValue] {
        var pending = lines
        var written: [String] = []
        let server = MCPServer(
            provider: provider,
            readLine: { pending.isEmpty ? nil : pending.removeFirst() },
            writeLine: { written.append($0) },
            logLine: { _ in }
        )
        server.run()
        return written.compactMap { try? JSONValue.parse($0) }
    }

    func testInitializeEchoesASupportedProtocolVersion() {
        let responses = exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        ])

        XCTAssertEqual(responses.count, 1)
        let result = responses[0]["result"]
        XCTAssertEqual(result?["protocolVersion"]?.stringValue, "2024-11-05")
        XCTAssertEqual(result?["serverInfo"]?["name"]?.stringValue, "trolley")
        XCTAssertNotNil(result?["capabilities"]?["tools"])
    }

    func testInitializeFallsBackForAnUnknownProtocolVersion() {
        let responses = exchange([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#
        ])

        XCTAssertEqual(responses[0]["result"]?["protocolVersion"]?.stringValue, MCPServer.preferredProtocolVersion)
    }

    func testStringIdsAreEchoedAsStrings() {
        let responses = exchange([#"{"jsonrpc":"2.0","id":"abc","method":"ping"}"#])

        XCTAssertEqual(responses[0]["id"]?.stringValue, "abc")
    }

    func testNotificationsProduceNoResponse() {
        let responses = exchange([
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#
        ])

        XCTAssertTrue(responses.isEmpty, "notifications must never be answered")
    }

    func testToolsListReportsDeclaredTools() {
        let provider = StubToolProvider(tools: [
            ToolDefinition(name: "click", description: "clicks", inputSchema: Schema.object([:]))
        ])
        let responses = exchange([#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#], provider: provider)

        let tools = responses[0]["result"]?["tools"]?.arrayValue
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"]?.stringValue, "click")
        XCTAssertNotNil(tools?.first?["inputSchema"])
    }

    func testToolCallForwardsArgumentsAndWrapsTheResult() throws {
        let provider = StubToolProvider(handler: { _, arguments in
            .object(["got": arguments["text"] ?? .null])
        })
        let responses = exchange([
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"echo","arguments":{"text":"안녕"}}}"#
        ], provider: provider)

        XCTAssertEqual(provider.calls.first?.name, "echo")
        let result = try XCTUnwrap(responses[0]["result"])
        XCTAssertEqual(result["isError"]?.boolValue, false)
        XCTAssertEqual(try result.toolPayload()["got"]?.stringValue, "안녕")
    }

    /// A failing tool is still a successful RPC -- the model has to be able to
    /// read the failure and react to it.
    func testToolErrorsBecomeIsErrorResultsNotRPCErrors() throws {
        let provider = StubToolProvider(handler: { _, _ in
            throw ToolError(.elementNotFound, "nope", hint: "try snapshot")
        })
        let responses = exchange([
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"echo"}}"#
        ], provider: provider)

        let result = try XCTUnwrap(responses[0]["result"])
        XCTAssertNil(responses[0]["error"])
        XCTAssertEqual(result["isError"]?.boolValue, true)
        let payload = try result.toolPayload()
        XCTAssertEqual(payload["error"]?["code"]?.stringValue, "ELEMENT_NOT_FOUND")
        XCTAssertEqual(payload["error"]?["hint"]?.stringValue, "try snapshot")
    }

    func testUnknownMethodIsAProtocolError() {
        let responses = exchange([#"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#])

        XCTAssertEqual(responses[0]["error"]?["code"]?.intValue, RPCErrorCode.methodNotFound.rawValue)
    }

    func testMalformedJSONReportsAParseError() {
        let responses = exchange(["{not json"])

        XCTAssertEqual(responses[0]["error"]?["code"]?.intValue, RPCErrorCode.parseError.rawValue)
    }

    func testBlankLinesAreIgnored() {
        XCTAssertTrue(exchange(["", "   "]).isEmpty)
    }

    /// The reserved key lets a tool attach an image without the base64 landing
    /// in the pretty-printed text the model reads.
    func testExtraContentBlocksRideAfterTheTextBlockAndLeaveThePayload() throws {
        let provider = StubToolProvider(handler: { _, _ in
            .object([
                "width": .int(4),
                MCPServer.extraContentKey: .array([
                    .object(["type": .string("image"), "data": .string("QUJD"), "mimeType": .string("image/jpeg")])
                ])
            ])
        })
        let responses = exchange([
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"echo"}}"#
        ], provider: provider)

        let content = try XCTUnwrap(responses[0]["result"]?["content"]?.arrayValue)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"]?.stringValue, "text", "text stays first -- clients and tests assume it")
        XCTAssertEqual(content[1]["type"]?.stringValue, "image")
        XCTAssertEqual(content[1]["data"]?.stringValue, "QUJD")

        let text = try XCTUnwrap(content[0]["text"]?.stringValue)
        XCTAssertFalse(text.contains("QUJD"), "the base64 must not leak into the text payload")
        XCTAssertFalse(text.contains(MCPServer.extraContentKey))
        XCTAssertTrue(text.contains("width"))
    }

    func testResponsesWithImageBlocksAreStillASingleLine() throws {
        let provider = StubToolProvider(handler: { _, _ in
            .object([
                MCPServer.extraContentKey: .array([
                    .object(["type": .string("image"), "data": .string(Data(repeating: 7, count: 900).base64EncodedString()), "mimeType": .string("image/jpeg")])
                ])
            ])
        })
        var pending = [#"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"echo"}}"#]
        var written: [String] = []
        MCPServer(
            provider: provider,
            readLine: { pending.isEmpty ? nil : pending.removeFirst() },
            writeLine: { written.append($0) },
            logLine: { _ in }
        ).run()

        XCTAssertEqual(written.count, 1)
        XCTAssertFalse(try XCTUnwrap(written.first).contains("\n"))
    }

    /// The transport is newline-delimited, so an embedded newline would split
    /// one message into two unparseable halves.
    func testResponsesAreASingleLine() throws {
        let provider = StubToolProvider(handler: { _, _ in .string("line one\nline two") })
        var pending = [#"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"echo"}}"#]
        var written: [String] = []
        MCPServer(
            provider: provider,
            readLine: { pending.isEmpty ? nil : pending.removeFirst() },
            writeLine: { written.append($0) },
            logLine: { _ in }
        ).run()

        XCTAssertEqual(written.count, 1)
        XCTAssertFalse(try XCTUnwrap(written.first).contains("\n"))
    }
}
