import AppKit
import Foundation

/// A captured pasteboard, as faithfully as another process can capture one.
public struct ClipboardSnapshot {
    /// One dictionary per pasteboard item: type identifier -> raw data.
    public let items: [[String: Data]]
    /// True when the contents were too large to copy, so `restore` would only
    /// put back part of what was there. Callers must report this rather than
    /// destroying the user's clipboard silently.
    public let truncated: Bool

    public init(items: [[String: Data]], truncated: Bool) {
        self.items = items
        self.truncated = truncated
    }

    public var isEmpty: Bool { items.isEmpty }
}

/// Seam over `NSPasteboard` so paste-based text entry is testable without
/// touching the real clipboard.
public protocol ClipboardAccessing {
    /// Increments whenever anything writes to the pasteboard, including us.
    var changeCount: Int { get }
    func snapshot() -> ClipboardSnapshot
    @discardableResult func writePlainText(_ text: String) -> Bool
    @discardableResult func restore(_ snapshot: ClipboardSnapshot) -> Bool
}

/// Real `NSPasteboard`-backed implementation.
///
/// Save-and-restore is best effort, and these limits are real:
///
/// - **Promised data is materialized or lost.** Reading a lazily-provided
///   flavor forces the owning app to produce it now; if it declines, that
///   flavor is dropped. File promises do not survive a round trip.
/// - **Ownership is lost.** After restoring, the originating app no longer owns
///   the pasteboard and cannot serve flavors it had only promised.
/// - **Large contents are left alone** rather than round-tripped through this
///   process; the snapshot reports itself as truncated instead.
public struct NSPasteboardClipboard: ClipboardAccessing {
    /// Above this, capturing costs more than the clipboard is worth to us --
    /// a large image or video on the pasteboard should not be copied here.
    static let captureByteLimit = 10 * 1024 * 1024

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public func snapshot() -> ClipboardSnapshot {
        guard let items = pasteboard.pasteboardItems else {
            return ClipboardSnapshot(items: [], truncated: false)
        }

        var captured: [[String: Data]] = []
        var total = 0
        for item in items {
            var flavors: [String: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                total += data.count
                if total > Self.captureByteLimit {
                    return ClipboardSnapshot(items: [], truncated: true)
                }
                flavors[type.rawValue] = data
            }
            if !flavors.isEmpty {
                captured.append(flavors)
            }
        }
        return ClipboardSnapshot(items: captured, truncated: false)
    }

    public func writePlainText(_ text: String) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }

    public func restore(_ snapshot: ClipboardSnapshot) -> Bool {
        guard !snapshot.truncated else { return false }

        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return true }

        let items = snapshot.items.map { flavors -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in flavors {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        return pasteboard.writeObjects(items)
    }
}
