import AppKit
import XCTest
@testable import TrolleyWidget

/// These assert attributes, not strings. The whole point of the change is what the text
/// *looks* like -- a test that only checked the characters would pass just as well
/// against the raw markdown it was written to replace.
final class MarkdownRenderingTests: XCTestCase {
    private func render(_ markdown: String) -> NSAttributedString {
        MarkdownRendering.attributed(markdown)
    }

    private func font(_ string: NSAttributedString, at index: Int) -> NSFont? {
        string.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    private func isBold(_ string: NSAttributedString, at index: Int) -> Bool {
        font(string, at: index)?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
    }

    // MARK: - The markup itself must be gone

    func testEmphasisMarkersAreNotShown() {
        let rendered = render("이건 **굵게** 입니다.")
        XCTAssertEqual(rendered.string, "이건 굵게 입니다.")
        XCTAssertFalse(rendered.string.contains("*"))
    }

    func testFencesAreNotShown() {
        let rendered = render("```\nlet x = 1\n```")
        XCTAssertFalse(rendered.string.contains("```"))
        XCTAssertTrue(rendered.string.contains("let x = 1"))
    }

    func testHeadingHashesAreNotShown() {
        let rendered = render("# 제목")
        XCTAssertEqual(rendered.string, "제목")
    }

    // MARK: - ...and replaced by something visible

    func testStrongTextIsActuallyBold() {
        let rendered = render("보통 **굵게**")
        let index = rendered.string.distance(
            from: rendered.string.startIndex,
            to: rendered.string.range(of: "굵게")!.lowerBound
        )
        XCTAssertTrue(isBold(rendered, at: index))
        XCTAssertFalse(isBold(rendered, at: 0), "보통 글자까지 굵어지면 강조가 아니다")
    }

    func testHeadingIsBiggerAndHeavierThanBody() {
        let heading = render("# 제목")
        let body = render("본문")
        let headingFont = font(heading, at: 0)!
        let bodyFont = font(body, at: 0)!
        XCTAssertGreaterThan(headingFont.pointSize, bodyFont.pointSize)
        XCTAssertNotEqual(headingFont.fontDescriptor.symbolicTraits.contains(.bold), false)
    }

    func testInlineCodeIsMonospaced() {
        let rendered = render("값은 `nil` 입니다")
        let index = rendered.string.distance(
            from: rendered.string.startIndex,
            to: rendered.string.range(of: "nil")!.lowerBound
        )
        XCTAssertTrue(font(rendered, at: index)!.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertFalse(font(rendered, at: 0)!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    /// Markdown's own `-` is eaten by the parser, so without a marker the items run
    /// together as unlabelled lines -- the exact opposite of the readability this is for.
    func testListItemsGetBulletsAndIndentation() {
        let rendered = render("- 하나\n- 둘")
        XCTAssertTrue(rendered.string.contains("• 하나"), rendered.string)
        XCTAssertTrue(rendered.string.contains("• 둘"), rendered.string)

        let paragraph = rendered.attribute(.paragraphStyle, at: 0, effectiveRange: nil)
            as? NSParagraphStyle
        XCTAssertGreaterThan(paragraph?.headIndent ?? 0, 0, "줄바꿈된 항목이 글머리 밑으로 돌아가면 안 된다")
    }

    func testOrderedListsKeepTheirNumbers() {
        let rendered = render("1. 먼저\n2. 다음")
        XCTAssertTrue(rendered.string.contains("1. 먼저"), rendered.string)
        XCTAssertTrue(rendered.string.contains("2. 다음"), rendered.string)
    }

    func testCodeBlockIsMonospaced() {
        let rendered = render("```\nswift build\n```")
        let index = rendered.string.range(of: "swift build").map {
            rendered.string.distance(from: rendered.string.startIndex, to: $0.lowerBound)
        }!
        XCTAssertTrue(font(rendered, at: index)!.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }

    // MARK: - Streaming

    /// Called on every token, so half-written markup is the normal case. If this throws
    /// away the text the answer flickers out and back on almost every emphasis.
    func testUnclosedEmphasisStillShowsItsText() {
        XCTAssertTrue(render("이건 **굵게 쓰다 만").string.contains("굵게 쓰다 만"))
        XCTAssertTrue(render("```\nlet x =").string.contains("let x ="))
        XCTAssertTrue(render("`nil").string.contains("nil"))
    }

    func testPartialTextIsNeverLost() {
        // Every prefix of a real answer has to render something, not nothing.
        let full = "### 결과\n\n- **크롬** 실행됨\n- `장위동` 검색됨"
        for length in 1...full.count {
            let prefix = String(full.prefix(length))
            XCTAssertFalse(
                render(prefix).string.isEmpty,
                "\(length)자에서 빈 화면이 됐다: \(prefix.debugDescription)"
            )
        }
    }

    func testEmptyRendersEmpty() {
        XCTAssertEqual(render("").string, "")
    }

    /// Plain prose is the common case and must survive untouched.
    func testPlainProseIsUnchanged() {
        XCTAssertEqual(render("크롬을 열었습니다.").string, "크롬을 열었습니다.")
    }

    /// The panel compares against this to decide whether to rewrite the text storage,
    /// and rewriting drops the reader's selection.
    func testPlainTextMatchesWhatIsRendered() {
        let markdown = "# 제목\n\n- 하나\n- 둘"
        XCTAssertEqual(MarkdownRendering.plainText(markdown), render(markdown).string)
    }
}
