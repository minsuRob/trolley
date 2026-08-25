import Foundation

/// Thin typed accessor over a tool's `arguments` object. Models routinely send
/// numbers as strings and vice versa, so the lookups are forgiving about the
/// JSON type but strict about presence.
struct Arguments {
    let raw: JSONValue

    init(_ raw: JSONValue) {
        self.raw = raw
    }

    func string(_ name: String) throws -> String {
        guard let value = optionalString(name) else {
            throw ToolError.missingArgument(name)
        }
        return value
    }

    /// Keeps an empty string as a real value, unlike `string`/`optionalString`,
    /// which read "" as "not supplied". Use this wherever empty is meaningful --
    /// clearing a field is a normal thing to ask for.
    func literalString(_ name: String) throws -> String {
        guard let value = raw[name], let text = value.stringValue else {
            throw ToolError.missingArgument(name)
        }
        return text
    }

    func optionalString(_ name: String) -> String? {
        guard let value = raw[name] else { return nil }
        if let text = value.stringValue {
            return text.isEmpty ? nil : text
        }
        if let number = value.intValue {
            return String(number)
        }
        return nil
    }

    func int(_ name: String, default fallback: Int) -> Int {
        guard let value = raw[name] else { return fallback }
        if let number = value.intValue { return number }
        if let text = value.stringValue, let number = Int(text) { return number }
        return fallback
    }

    func double(_ name: String, default fallback: Double) -> Double {
        guard let value = raw[name] else { return fallback }
        if let number = value.doubleValue { return number }
        if let text = value.stringValue, let number = Double(text) { return number }
        return fallback
    }

    func bool(_ name: String, default fallback: Bool) -> Bool {
        guard let value = raw[name] else { return fallback }
        if let flag = value.boolValue { return flag }
        if let text = value.stringValue { return text == "true" }
        return fallback
    }

    func stringArray(_ name: String) -> [String] {
        guard let value = raw[name] else { return [] }
        if let array = value.arrayValue {
            return array.compactMap(\.stringValue)
        }
        if let single = value.stringValue {
            return [single]
        }
        return []
    }
}

/// JSON Schema builders for tool input schemas.
enum Schema {
    static func object(_ properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    static func string(_ description: String) -> JSONValue {
        .object(["type": .string("string"), "description": .string(description)])
    }

    static func integer(_ description: String, default fallback: Int? = nil) -> JSONValue {
        var property: [String: JSONValue] = [
            "type": .string("integer"),
            "description": .string(description)
        ]
        if let fallback { property["default"] = .int(fallback) }
        return .object(property)
    }

    static func number(_ description: String, default fallback: Double? = nil) -> JSONValue {
        var property: [String: JSONValue] = [
            "type": .string("number"),
            "description": .string(description)
        ]
        if let fallback { property["default"] = .double(fallback) }
        return .object(property)
    }

    static func boolean(_ description: String, default fallback: Bool? = nil) -> JSONValue {
        var property: [String: JSONValue] = [
            "type": .string("boolean"),
            "description": .string(description)
        ]
        if let fallback { property["default"] = .bool(fallback) }
        return .object(property)
    }

    static func enumString(
        _ description: String,
        values: [String],
        default fallback: String? = nil
    ) -> JSONValue {
        var property: [String: JSONValue] = [
            "type": .string("string"),
            "enum": .array(values.map { .string($0) }),
            "description": .string(description)
        ]
        if let fallback { property["default"] = .string(fallback) }
        return .object(property)
    }

    static func stringArray(_ description: String) -> JSONValue {
        .object([
            "type": .string("array"),
            "items": .object(["type": .string("string")]),
            "description": .string(description)
        ])
    }
}
