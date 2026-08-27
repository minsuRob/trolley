import AppKit
import Foundation

/// Turns the model's markdown into something a person reads instead of parses.
///
/// The answer box printed the source. `**굵게**`, `- 목록`, ``` fences -- all of it
/// literal, in the one place someone looks for a reply. A chat that shows its own markup
/// is showing its wiring.
///
/// The parsing is Foundation's, not ours. `AttributedString(markdown:)` with
/// `interpretedSyntax: .full` leaves block structure behind as `presentationIntent`
/// attributes, so what is left here is a mapping from those intents to fonts and
/// paragraph styles -- which is the part that has to match this panel, and the only part
/// worth writing by hand.
public enum MarkdownRendering {
    /// Two sizes, because two surfaces read markdown now and they are not the same
    /// shape: a 360pt panel showing an answer as it streams, and a resizable window
    /// showing a wiki page someone means to actually read.
    public struct Style {
        let body: NSFont
        let mono: NSFont
        let textColor: NSColor
        let secondaryColor: NSColor

        public init(body: NSFont, mono: NSFont, textColor: NSColor, secondaryColor: NSColor) {
            self.body = body
            self.mono = mono
            self.textColor = textColor
            self.secondaryColor = secondaryColor
        }

        /// Small, with tighter indents than a document would use -- 360pt is not much.
        public static let panel = Style(
            body: .systemFont(ofSize: 11),
            mono: .monospacedSystemFont(ofSize: 10, weight: .regular),
            textColor: .labelColor,
            secondaryColor: .secondaryLabelColor
        )

        /// A page being read rather than a reply being watched.
        public static let document = Style(
            body: .systemFont(ofSize: 13),
            mono: .monospacedSystemFont(ofSize: 12, weight: .regular),
            textColor: .labelColor,
            secondaryColor: .secondaryLabelColor
        )
    }

    /// - Parameter markdown: may be half-written. This is called on every streamed
    ///   token, so an unclosed `**` or an unterminated fence is the normal case, not an
    ///   error -- see `failurePolicy` below.
    public static func attributed(_ markdown: String, style: Style = .panel) -> NSAttributedString {
        guard !markdown.isEmpty else { return NSAttributedString() }

        let parsed: AttributedString
        do {
            parsed = try AttributedString(
                markdown: markdown,
                options: .init(
                    // Without this a mid-stream `**굵게` throws and the whole answer
                    // blanks out until the closing asterisks arrive -- the text would
                    // flicker away and back on almost every emphasis.
                    allowsExtendedAttributes: false,
                    interpretedSyntax: .full,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
        } catch {
            // Nothing salvageable. The source is still the answer, so show it plainly
            // rather than showing nothing.
            return NSAttributedString(
                string: markdown,
                attributes: [.font: style.body, .foregroundColor: style.textColor]
            )
        }

        let output = NSMutableAttributedString()
        var lastBlockID: [Int] = []

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            guard !text.isEmpty else { continue }

            let intent = run.presentationIntent
            let block = blockKind(of: intent)
            let identity = intent?.components.map(\.identity) ?? []

            // Runs carry their block intent individually; a new identity means a new
            // paragraph, and that is where list markers and separating newlines belong.
            if identity != lastBlockID, !output.string.isEmpty {
                output.append(NSAttributedString(string: "\n"))
            }
            if identity != lastBlockID, let marker = marker(for: intent) {
                output.append(NSAttributedString(
                    string: marker,
                    attributes: [.font: style.body, .foregroundColor: style.secondaryColor,
                                 .paragraphStyle: paragraph(for: block)]
                ))
            }
            lastBlockID = identity

            output.append(NSAttributedString(
                string: text,
                attributes: attributes(run: run, block: block, style: style)
            ))
        }

        // Markup that has arrived but has no content yet parses to nothing at all: a
        // bare `###` is a heading with an empty title. Returning that empty result blanks
        // the answer box for as long as it takes to type the rest of the line, so the
        // text visibly drops out and comes back -- caught by `testPartialTextIsNeverLost`
        // at exactly the four keystrokes `#`, `##`, `###`, `### `. Show the source
        // instead; a plain-text chat would have shown it anyway.
        guard output.length > 0 else {
            return NSAttributedString(
                string: markdown,
                attributes: [.font: style.body, .foregroundColor: style.textColor]
            )
        }
        return output
    }

    /// What `attributed` will put on screen for this source, without building it.
    ///
    /// The panel compares against the rendered text to decide whether anything changed,
    /// and comparing against the *source* would rewrite the storage on every refresh --
    /// which drops any selection the reader had made in a finished answer.
    static func plainText(_ markdown: String) -> String {
        attributed(markdown).string
    }

    // MARK: - Blocks

    private enum Block {
        case body
        case heading(level: Int)
        case listItem
        case code
        case quote
    }

    private static func blockKind(of intent: PresentationIntent?) -> Block {
        guard let intent else { return .body }
        // Innermost first: a code block inside a list item is code, and a list item
        // inside a quote is still a list item.
        for component in intent.components {
            switch component.kind {
            case .header(let level): return .heading(level: level)
            case .codeBlock: return .code
            case .blockQuote: return .quote
            case .listItem: return .listItem
            default: continue
            }
        }
        return .body
    }

    /// The bullet or number a list item is drawn with. Markdown's own `-` and `1.` are
    /// consumed by the parser, so without this the items run together as plain lines.
    private static func marker(for intent: PresentationIntent?) -> String? {
        guard let intent else { return nil }
        var ordinal: Int?
        var isOrdered = false
        for component in intent.components {
            switch component.kind {
            case .listItem(let number): ordinal = number
            case .orderedList: isOrdered = true
            default: continue
            }
        }
        guard let ordinal else { return nil }
        return isOrdered ? "\(ordinal). " : "• "
    }

    private static func paragraph(for block: Block) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        switch block {
        case .listItem:
            // headIndent, not just firstLineHeadIndent: a wrapped list item has to line
            // up under its own text rather than back under the bullet.
            style.firstLineHeadIndent = 4
            style.headIndent = 16
            style.paragraphSpacing = 1
        case .quote, .code:
            style.firstLineHeadIndent = 8
            style.headIndent = 8
            style.paragraphSpacing = 2
        case .heading:
            style.paragraphSpacingBefore = 4
            style.paragraphSpacing = 2
        case .body:
            style.paragraphSpacing = 3
        }
        return style
    }

    // MARK: - Inline

    private static func attributes(
        run: AttributedString.Runs.Run, block: Block, style: Style
    ) -> [NSAttributedString.Key: Any] {
        var font = style.body
        var color = style.textColor

        switch block {
        case .heading(let level):
            // Two steps for a top-level heading, one for everything below it. A panel
            // this narrow cannot spend more than that on hierarchy.
            font = .systemFont(ofSize: level <= 1 ? 13 : 12, weight: .semibold)
        case .code:
            font = style.mono
            color = style.secondaryColor
        case .quote:
            color = style.secondaryColor
        case .listItem, .body:
            break
        }

        // Inline styles ride on top of the block's font so `**굵게**` inside a list item
        // keeps the list item's size.
        if let inline = run.inlinePresentationIntent {
            if inline.contains(.code) {
                font = style.mono
            }
            if inline.contains(.stronglyEmphasized) {
                font = withTrait(.bold, on: font)
            }
            if inline.contains(.emphasized) {
                font = withTrait(.italic, on: font)
            }
            if inline.contains(.strikethrough) {
                return [
                    .font: font, .foregroundColor: style.secondaryColor,
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .paragraphStyle: paragraph(for: block)
                ]
            }
        }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph(for: block)
        ]
        // Links stay clickable; the text view is selectable, which is what makes them
        // reachable at all.
        if let link = run.link {
            attributes[.link] = link
            attributes[.foregroundColor] = NSColor.linkColor
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        return attributes
    }

    private static func withTrait(
        _ trait: NSFontDescriptor.SymbolicTraits, on font: NSFont
    ) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(
            font.fontDescriptor.symbolicTraits.union(trait)
        )
        // A monospaced face may have no italic cut; keeping the upright one beats
        // falling back to a different family mid-sentence.
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }
}
