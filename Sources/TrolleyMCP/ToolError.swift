import Foundation

/// Structured tool failures. These are surfaced to the model as `isError: true`
/// results rather than JSON-RPC errors, so the hint text is the model's main
/// signal about what to try next.
public struct ToolError: Error, Equatable {
    public enum Code: String {
        case notTrusted = "NOT_TRUSTED"
        case appNotFound = "APP_NOT_FOUND"
        case appNotRunning = "APP_NOT_RUNNING"
        case elementNotFound = "ELEMENT_NOT_FOUND"
        case elementStale = "ELEMENT_STALE"
        case invalidElementID = "INVALID_ELEMENT_ID"
        case unknownKey = "UNKNOWN_KEY"
        case screenRecordingDenied = "SCREEN_RECORDING_DENIED"
        case unsupportedText = "UNSUPPORTED_TEXT"
        case clipboardFailed = "CLIPBOARD_FAILED"
        case inputSourceFailed = "INPUT_SOURCE_FAILED"
        case actionFailed = "ACTION_FAILED"
        case timeout = "TIMEOUT"
        case invalidArgument = "INVALID_ARGUMENT"
    }

    public let code: Code
    public let message: String
    public let hint: String?

    public init(_ code: Code, _ message: String, hint: String? = nil) {
        self.code = code
        self.message = message
        self.hint = hint
    }

    public var jsonValue: JSONValue {
        var error: [String: JSONValue] = [
            "code": .string(code.rawValue),
            "message": .string(message)
        ]
        if let hint {
            error["hint"] = .string(hint)
        }
        return .object(["error": .object(error)])
    }
}

public extension ToolError {
    static func notTrusted(executablePath: String) -> ToolError {
        ToolError(
            .notTrusted,
            "trolley is not trusted for Accessibility.",
            hint: "Grant Accessibility to this exact binary: \(executablePath). "
                + "System Settings > Privacy & Security > Accessibility. Trust is per executable path, "
                + "and is granted to trolley itself -- not to the MCP client that launched it."
        )
    }

    static func appNotRunning(_ bundleID: String) -> ToolError {
        ToolError(
            .appNotRunning,
            "\(bundleID) is not running.",
            hint: "Call launch_app with this bundleId first."
        )
    }

    static func elementNotFound(text: String, bundleID: String) -> ToolError {
        ToolError(
            .elementNotFound,
            "No element in \(bundleID) matches \"\(text)\".",
            hint: "Call snapshot to see what is actually exposed. Chromium/Electron web content "
                + "often does not expose its inner tree at all -- if the app is one of those, the "
                + "element may be unreachable via AX regardless of the query; use the screenshot "
                + "tool and click_at on what you see instead."
        )
    }

    static func elementStale(_ id: String) -> ToolError {
        ToolError(
            .elementStale,
            "Element \(id) no longer exists.",
            hint: "The UI changed since it was captured. Re-run snapshot or find_elements for fresh ids."
        )
    }

    static func invalidElementID(_ id: String) -> ToolError {
        ToolError(
            .invalidElementID,
            "Unknown element id \"\(id)\".",
            hint: "Element ids come from snapshot or find_elements in this same session."
        )
    }

    static func missingArgument(_ name: String) -> ToolError {
        ToolError(.invalidArgument, "Missing required argument \"\(name)\".")
    }

    static func screenRecordingDenied(executablePath: String) -> ToolError {
        ToolError(
            .screenRecordingDenied,
            "trolley does not have Screen Recording permission.",
            hint: "Grant Screen Recording to this exact binary: \(executablePath). "
                + "System Settings > Privacy & Security > Screen Recording. This permission is separate "
                + "from Accessibility, and unlike it, only applies to processes launched after the grant "
                + "-- restart trolley (reconnect the MCP server) once granted."
        )
    }

    static func unsupportedText(_ characters: String) -> ToolError {
        ToolError(
            .unsupportedText,
            "method=\"keys\" types by physical key position and cannot produce: \(characters)",
            hint: "Use the default method=\"paste\", which carries any Unicode including Korean and emoji."
        )
    }

    static func clipboardFailed(_ message: String) -> ToolError {
        ToolError(
            .clipboardFailed,
            message,
            hint: "Nothing was typed and the clipboard was left as it was. "
                + "Try method=\"keys\" for ASCII text, or set_ax_value."
        )
    }

    static func inputSourceFailed(_ message: String) -> ToolError {
        ToolError(
            .inputSourceFailed,
            message,
            hint: "method=\"keys\" needs an ASCII-capable keyboard layout (such as ABC) to be installed. "
                + "Add one in System Settings > Keyboard > Input Sources, or use method=\"paste\"."
        )
    }
}
