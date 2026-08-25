import Foundation

/// JSON-RPC 2.0 ids are either a string or a number; both must be echoed back
/// in the response with the same type the client used.
public enum RequestID: Codable, Equatable {
    case string(String)
    case number(Int)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "id must be a string or a number")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        }
    }

    var jsonValue: JSONValue {
        switch self {
        case .string(let value): return .string(value)
        case .number(let value): return .int(value)
        }
    }
}

public struct RPCRequest: Decodable {
    public let jsonrpc: String
    /// Absent for notifications, which must not be answered.
    public let id: RequestID?
    public let method: String
    public let params: JSONValue?

    public var isNotification: Bool { id == nil }
}

/// Standard JSON-RPC error codes. Note these signal *protocol* failures; a tool
/// that runs and fails is a successful call carrying `isError: true`.
public enum RPCErrorCode: Int {
    case parseError = -32700
    case invalidRequest = -32600
    case methodNotFound = -32601
    case invalidParams = -32602
    case internalError = -32603
}

public enum RPCResponse {
    case result(id: RequestID, value: JSONValue)
    case failure(id: RequestID?, code: RPCErrorCode, message: String)

    public func jsonValue() -> JSONValue {
        switch self {
        case .result(let id, let value):
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id.jsonValue,
                "result": value
            ])
        case .failure(let id, let code, let message):
            return .object([
                "jsonrpc": .string("2.0"),
                "id": id?.jsonValue ?? .null,
                "error": .object([
                    "code": .int(code.rawValue),
                    "message": .string(message)
                ])
            ])
        }
    }
}
