import CoreGraphics
import Foundation

/// Real CGEvent-backed mouse click, used as the fallback when AXPress no-ops
/// (some Chromium/Electron-drawn widgets never respond to AXPress).
///
/// Lives in TrolleyKit rather than the CLI so both the CLI and the MCP server
/// can inject it as `ActionExecutor.mouseClicker`.
public enum MouseSynthesizer {
    public static func click(at point: CGPoint) {
        let source: CGEventSource? = nil
        let down = CGEvent(mouseEventSource: source, mouseType: .leftMouseDown, mouseCursorPosition: point, mouseButton: .left)
        let up = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: point, mouseButton: .left)
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
