import Foundation

/// The frontmatter block at the top of a `markhub-llm-wiki` page, and nothing else.
///
/// This is the whole reason the wiki can be carried into a 96K-token context. The
/// vault is 160 files and 411KB; its bodies are ~100K tokens, which is more than
/// the local model's measured soft limit on its own. But every page that matters
/// declares what it is in ten lines at the top, and those ten lines are what a
/// question actually needs in front of it. So indexing never reads a body -- the
/// walker hands this at most the first 8KB of a file and this stops at the closing
/// `---`, usually inside 400 bytes.
///
/// The rules are copied from the vault's own indexer,
/// `.claude/skills/reindex/reindex.py`, quirks included: line 0 must be `---`, only
/// the ten known keys are recognised, an empty value means "the list is on the
/// following indented lines", and surrounding quotes are stripped. Copied rather
/// than improved on purpose. A real YAML parser would accept documents reindex.py
/// silently drops, and then `trolley wiki --json` and the vault's own `INDEX.md`
/// would disagree about what the wiki contains -- with no way to tell which one is
/// wrong. Matching the existing parser makes that comparison an oracle instead.
public enum WikiFrontmatter {
    public enum Value: Equatable {
        case scalar(String)
        case list([String])
    }

    /// The complete key set, matching reindex.py's `FIELD_RE`. Anything else on a
    /// line is ignored rather than stored: restricting the keys is what keeps a
    /// body line like `## 배경: 왜` from being read as a field if a page is ever
    /// missing its closing `---`.
    public static let fields: Set<String> = [
        "유형", "상태", "분류", "영역", "우선순위", "담당", "요약", "생성일", "갱신일", "출처"
    ]

    /// Splits at most `maxLines` lines off the front of `text` and parses those.
    ///
    /// The cap is the second half of the cheapness guarantee. The walker already
    /// limits how many *bytes* it reads; this limits how many lines are scanned, so
    /// a page whose frontmatter is malformed and never closes cannot drag the whole
    /// body through the parser. 60 lines is roughly four times the longest real
    /// block in the vault.
    public static func scan(_ text: String, maxLines: Int = 60) -> [String: Value] {
        var lines: [Substring] = []
        lines.reserveCapacity(maxLines)
        var cursor = text.startIndex
        while lines.count < maxLines, cursor < text.endIndex {
            // `isNewline` rather than a search for "\n": Swift treats CRLF as a single
            // Character, so a file written on Windows contains no bare "\n" at all and
            // a search for one would return the entire file as one line.
            if let newline = text[cursor...].firstIndex(where: \.isNewline) {
                lines.append(text[cursor..<newline])
                cursor = text.index(after: newline)
            } else {
                lines.append(text[cursor...])
                break
            }
        }
        return parse(lines: lines)
    }

    /// Returns `[:]` when line 0 is not `---`.
    ///
    /// That empty result is not an error -- it is the mechanism. Twenty files in the
    /// vault have no frontmatter (`INDEX.md` at 21KB, `CLAUDE.md` at 20KB, `LOG.md`,
    /// every `README.md`, `context/sources/*`, all of `logs/**`), and they are more
    /// than half its bytes. They fall out here, before anything is allocated for
    /// them, without a second exclusion list to keep in sync.
    public static func parse(lines: [Substring]) -> [String: Value] {
        guard let opening = lines.first, trim(opening) == "---" else { return [:] }

        var parsed: [String: Value] = [:]
        var index = 1
        while index < lines.count {
            if trim(lines[index]) == "---" { break }
            guard let (key, rawValue) = field(in: lines[index]) else {
                index += 1
                continue
            }

            let value = unquote(rawValue)
            // An empty value is YAML's way of saying the value is the indented block
            // underneath. `[]` is the inline empty list, which occurs in the vault as
            // `출처: []` and means the same thing as no items at all.
            if value.isEmpty || value == "[]" {
                var items: [String] = []
                var lookahead = index + 1
                while lookahead < lines.count, let item = listItem(in: lines[lookahead]) {
                    items.append(item)
                    lookahead += 1
                }
                parsed[key] = items.isEmpty ? .scalar("") : .list(items)
                index = lookahead
            } else {
                parsed[key] = .scalar(value)
                index += 1
            }
        }
        return parsed
    }

    // MARK: - Reading values out

    /// A single value, taking the first item when the field happens to be a list.
    /// `영역` is the field that is sometimes one and sometimes the other, and the
    /// row renderers want a string either way.
    public static func scalar(_ value: Value?) -> String {
        switch value {
        case .scalar(let text): return text
        case .list(let items): return items.first ?? ""
        case nil: return ""
        }
    }

    /// Every value, normalising a scalar to a one-element array. An empty scalar
    /// yields no elements rather than one empty string -- `영역: ""` appears twelve
    /// times in the vault and means "unassigned area", not "an area named nothing".
    public static func list(_ value: Value?) -> [String] {
        switch value {
        case .scalar(let text): return text.isEmpty ? [] : [text]
        case .list(let items): return items.filter { !$0.isEmpty }
        case nil: return []
        }
    }

    // MARK: - Line shapes

    /// `키: 값` at the very start of the line, and only for the ten known keys.
    static func field(in line: Substring) -> (key: String, value: Substring)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = String(line[line.startIndex..<colon])
        guard fields.contains(key) else { return nil }
        var value = line[line.index(after: colon)...]
        // reindex.py's `\s?` -- exactly one optional space after the colon, the rest
        // is the value. Trimming happens in `unquote`.
        if value.first == " " { value = value.dropFirst() }
        return (key, value)
    }

    /// An indented `- item` line belonging to the field above it.
    static func listItem(in line: Substring) -> String? {
        guard line.first == " " || line.first == "\t" else { return nil }
        let body = trim(line)
        guard body.hasPrefix("- ") else { return nil }
        return unquote(body.dropFirst(2)[...])
    }

    /// Trims surrounding whitespace, then one matched pair of quotes, then whatever
    /// whitespace that exposed. `요약` is always quoted in the vault and routinely
    /// contains `:`, so the value has to be taken as everything after the first
    /// colon rather than re-split.
    static func unquote(_ raw: Substring) -> String {
        var text = trim(raw)
        if text.count >= 2, let first = text.first, let last = text.last,
           first == last, first == "\"" || first == "'" {
            text = String(text.dropFirst().dropLast())
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    /// Whitespace *and* newlines: the vault is LF today, but a page edited on
    /// another machine would leave a `\r` on the end of every line, and a `---`
    /// with a carriage return after it would not close the block.
    private static func trim(_ raw: Substring) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trim(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
