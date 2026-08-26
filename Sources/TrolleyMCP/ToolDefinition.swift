import Foundation
import TrolleyKit

/// One tool, as the model is told about it.
///
/// Split out of the MCP server when that server was removed (`docs/MCP-보류.md`).
/// The schema outlives the protocol that used to carry it: the local model's turn
/// loop reads the same catalog, and `TrolleyToolRunner` is what walks it now.
public struct ToolDefinition {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

/// The set of tools something exposes. Implemented by `TrolleyTools`; whatever
/// calls them knows nothing about accessibility.
public protocol ToolProviding {
    var tools: [ToolDefinition] { get }
    /// Throwing `ToolError` produces an error result for the model.
    func call(name: String, arguments: JSONValue) throws -> JSONValue
}
