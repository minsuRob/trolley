import CoreGraphics
import Foundation

public struct AXTreeDumper {
    public init() {}

    /// - Parameter includeFrames: append each element's position and size in screen
    ///   points. Off by default because most walks are looking for *what* is on screen;
    ///   on when the question is *where* -- a column that runs past the edge of its
    ///   list, a pane that took the width its neighbour needed. Without it the only way
    ///   to check a layout was to ask System Events, which is a second automation stack
    ///   for a fact trolley already holds.
    public func dump(
        root: AXElementProviding, limits: AXTraversalLimits, includeFrames: Bool = false
    ) -> String {
        var lines: [String] = []
        let walker = AXTreeWalker()
        walker.walk(root: root, limits: limits) { element, depth, _ in
            let indent = String(repeating: "  ", count: depth)
            let role = element.stringAttribute(AXAttr.role) ?? "?"
            let title = element.stringAttribute(AXAttr.title) ?? ""
            let value = truncate(element.stringAttribute(AXAttr.value) ?? "")
            let description = element.stringAttribute(AXAttr.description) ?? ""
            let childCount = element.children().count
            let frame = includeFrames
                ? " | " + Self.frameField(
                    position: element.pointAttribute(AXAttr.position),
                    size: element.sizeAttribute(AXAttr.size)
                )
                : ""
            lines.append(
                "\(indent)\(role) | title=\(title) | value=\(value) | desc=\(description)"
                    + "\(frame) | children=\(childCount)"
            )
        }
        return lines.joined(separator: "\n")
    }

    /// `frame=490,107 940x652`, or `frame=?` for an element that reports neither -- a
    /// menu bar item, a window that has not been placed yet. Rounded to whole points:
    /// AppKit hands back halves on a Retina screen and nobody is verifying a layout to
    /// half a point.
    public static func frameField(position: CGPoint?, size: CGSize?) -> String {
        guard position != nil || size != nil else { return "frame=?" }
        let origin = position.map { "\(Int($0.x.rounded())),\(Int($0.y.rounded()))" } ?? "?"
        let extent = size.map { "\(Int($0.width.rounded()))x\(Int($0.height.rounded()))" } ?? "?"
        return "frame=\(origin) \(extent)"
    }

    private func truncate(_ text: String, limit: Int = 80) -> String {
        guard text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }
}
