import AppKit
import XCTest
@testable import trolley

/// The bug this file exists to keep out: `NSBox.contentView` was handed an Auto
/// Layout stack, and `NSBox` does not constrain a content view it did not create.
/// The whole filter grid drew unpositioned, upward and out of the box, across the
/// heading and the path row -- so 유형/상태/분류/우선순위/영역/담당 were stacked on
/// top of other controls and could not be clicked at all.
///
/// A layout bug looks like nothing in a unit test unless the test measures frames,
/// so that is what this does: lay the window out and check that no two controls
/// claim the same pixels.
final class WikiSettingsLayoutTests: XCTestCase {
    /// Creating an `NSWindow` before `NSApplication` exists is not supported.
    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
    }

    func testNoTwoControlsOverlap() {
        let controller = WikiSettingsWindowController()
        let root = controller.contentViewForTesting
        root.layoutSubtreeIfNeeded()

        let controls = Self.controls(in: root).map {
            (view: $0, frame: $0.convert($0.bounds, to: root))
        }
        XCTAssertGreaterThan(controls.count, 15, "컨트롤을 찾지 못했습니다 — 검사가 무의미해집니다.")

        for (index, first) in controls.enumerated() {
            for second in controls[(index + 1)...] {
                // `intersects` is true for a shared edge, which stacked rows have.
                let overlap = first.frame.intersection(second.frame)
                XCTAssertTrue(
                    overlap.isNull || overlap.width < 1 || overlap.height < 1,
                    "\(Self.name(first.view)) 와 \(Self.name(second.view)) 가 겹칩니다: "
                        + "\(first.frame) / \(second.frame)"
                )
            }
        }
    }

    /// Every control has to be inside the window's content, not merely somewhere in
    /// the coordinate space. A control laid out past the bottom edge is exactly as
    /// unusable as one buried under another, and nothing on screen says so.
    func testEveryControlIsInsideTheContentView() {
        let controller = WikiSettingsWindowController()
        let root = controller.contentViewForTesting
        root.layoutSubtreeIfNeeded()

        for control in Self.controls(in: root) {
            let frame = control.convert(control.bounds, to: root)
            XCTAssertTrue(
                root.bounds.insetBy(dx: -1, dy: -1).contains(frame),
                "\(Self.name(control)) 가 창 밖에 있습니다: \(frame) ⊄ \(root.bounds)"
            )
        }
    }

    // MARK: - Helpers

    /// Controls only. Container views legitimately overlap their own children, and
    /// a control is the thing a person has to be able to hit.
    private static func controls(in view: NSView) -> [NSControl] {
        view.subviews.flatMap { subview -> [NSControl] in
            if let control = subview as? NSControl, !(control is NSTextView) {
                return [control]
            }
            return controls(in: subview)
        }
    }

    private static func name(_ control: NSControl) -> String {
        if let button = control as? NSButton, !button.title.isEmpty { return button.title }
        if let popup = control as? NSPopUpButton {
            return "팝업(\(popup.itemTitles.prefix(2).joined(separator: "/")))"
        }
        if let field = control as? NSTextField {
            let text = field.stringValue.isEmpty ? field.placeholderString ?? "" : field.stringValue
            return text.isEmpty ? "\(type(of: control))" : "'\(text)'"
        }
        return "\(type(of: control))"
    }
}
