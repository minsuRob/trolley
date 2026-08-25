import CoreGraphics
import Foundation

/// Executes `TrolleyAction`s against a live (or fake) AX tree. This is the
/// "여러가지 케이스" primitive layer the higher-level scenarios compose.
public struct ActionExecutor {
    public let root: AXElementProviding
    public let walker: AXTreeWalker
    public let keyPoster: KeyEventPosting
    public var limits: AXTraversalLimits
    /// Posts a real mouse click; used only as a fallback when AXPress fails.
    public var mouseClicker: ((CGPoint) -> Void)?

    public init(
        root: AXElementProviding,
        walker: AXTreeWalker = AXTreeWalker(),
        keyPoster: KeyEventPosting,
        limits: AXTraversalLimits = AXTraversalLimits(),
        mouseClicker: ((CGPoint) -> Void)? = nil
    ) {
        self.root = root
        self.walker = walker
        self.keyPoster = keyPoster
        self.limits = limits
        self.mouseClicker = mouseClicker
    }

    @discardableResult
    public func perform(_ action: TrolleyAction) -> ActionResult {
        switch action {
        case .findElement(let query):
            let matches = walker.findAll(root: root, query: query, limits: limits)
            return .elementFound(matches)

        case .click(let element):
            if element.performAction(AXAction.press) {
                return .ok
            }
            // Fallback: some Chromium/Electron-drawn widgets don't respond to
            // AXPress at all; synthesize a real mouse click at its screen center.
            if let position = element.pointAttribute(AXAttr.position),
               let size = element.sizeAttribute(AXAttr.size),
               let mouseClicker {
                let center = CGPoint(x: position.x + size.width / 2, y: position.y + size.height / 2)
                mouseClicker(center)
                return .ok
            }
            return .failed("click failed: AXPress no-op and no mouse fallback available")

        case .focus(let element):
            if element.setAttribute(AXAttr.focused, value: true as CFBoolean) {
                return .ok
            }
            return perform(.click(element))

        case .key(let name, let modifiers):
            KeyboardActions.press(name, modifiers: modifiers, using: keyPoster)
            return .ok

        case .type(let text):
            // Deliberately never falls back to AXUIElementSetAttributeValue(kAXValueAttribute):
            // that silently no-ops on Notion's rich-text editor.
            KeyboardActions.type(text, using: keyPoster)
            return .ok

        case .wait(let seconds):
            Thread.sleep(forTimeInterval: seconds)
            return .ok
        }
    }
}
