import CryptoKit
import Foundation

/// The text that actually travels to the model.
public struct WikiDigest: Equatable {
    public let text: String
    /// Identifies this exact content. What `WikiInjection` compares to decide
    /// whether the model has already been told.
    public let hash: String
    /// Lines rendered.
    public let matched: Int
    /// Pages that passed the filter, before the character budget cut in.
    public let total: Int
    public let characters: Int

    public var isEmpty: Bool { matched == 0 }
    public var wasTruncated: Bool { matched < total }

    public init(text: String, hash: String, matched: Int, total: Int, characters: Int) {
        self.text = text
        self.hash = hash
        self.matched = matched
        self.total = total
        self.characters = characters
    }
}

/// Turns pages into the compact list a question carries in front of it.
///
/// One line per page, no bodies. Measured against the real vault: all 110 pages come
/// to 7,664 characters (~3.5K tokens, under 4% of the model's 96K soft limit), and
/// the default 진행중 filter is 65 pages at 4,481 characters. A single page *body*,
/// by contrast, runs to 7KB on its own -- which is why bodies are only ever fetched
/// one at a time, on request, through the `wiki_read` tool.
public enum WikiDigestRenderer {
    /// Sized so the default filter never truncates.
    ///
    /// Measured against the real vault: the 65 진행중 pages render to ~8,100
    /// characters at this line format, so 4,000 -- the first number tried -- silently
    /// dropped 35 of them. That is the worst failure this feature has, because a
    /// shortened list reads to the model as a complete one and it answers "that is
    /// all of them" about work it was never shown. Better to spend the characters.
    ///
    /// 9,000 characters is roughly 4.1K tokens of Korean: 4.3% of the model's 96K
    /// soft limit, and about 0.35GB against `context_guard.py`'s measured fit
    /// (`peak_GB ≈ 18.0 + 0.085 * tokens/1000`). Paid once per conversation.
    public static let defaultBudget = 9_000

    /// Characters to tokens, at the 2.2 ratio measured on this vault's Korean.
    ///
    /// One copy on purpose. Three screens quote this number back at the same
    /// person -- the setup window, the wiki settings window and `trolley wiki` --
    /// and two of them disagreeing about one folder would read as a bug in the
    /// folder. There is no tokenizer on this side, the server holds it, so an
    /// estimate is the most any caller can have.
    public static func approximateTokens(characters: Int) -> Int {
        Int(Double(characters) / 2.2)
    }

    public static func render(
        pages: [WikiPage],
        filter: WikiFilter,
        rootName: String,
        budgetCharacters: Int = defaultBudget,
        today: Date = Date()
    ) -> WikiDigest {
        let (kept, droppedByCount) = filter.apply(to: pages, today: today)
        let total = kept.count + droppedByCount

        let header = """
            [위키] \(rootName) — \(describe(filter)) (%MATCHED%/\(total)건)
            아래는 참고용 목록입니다. 각 줄은 「제목 · 상태 · 분류 · 우선순위 · 영역 · 담당 · 갱신일\(filter.includeSummary ? " · 요약" : "")」입니다.
            본문은 포함되어 있지 않습니다. 목록에 없는 내용을 추측해서 말하지 마세요.


            """

        // The budget is spent on lines, so the header and a worst-case footer are
        // reserved before the first one is measured. Otherwise a list that just fits
        // would be pushed over by the note explaining that it did not.
        let footerReserve = 40
        var remaining = budgetCharacters - header.count - footerReserve
        var lines: [String] = []
        for page in kept {
            let rendered = line(for: page, includeSummary: filter.includeSummary)
            // Cut between records, never inside one: half a line is a page the model
            // cannot name and cannot look up.
            guard remaining - (rendered.count + 1) >= 0 else { break }
            remaining -= rendered.count + 1
            lines.append(rendered)
        }

        let omitted = total - lines.count
        var body = header.replacingOccurrences(of: "%MATCHED%", with: String(lines.count))
        body += lines.joined(separator: "\n")
        if omitted > 0 {
            // Always said out loud. A quietly shortened list is a lie to the model:
            // it will answer "that is all of them" about a list it was never given.
            body += "\n(예산 \(budgetCharacters)자 상한으로 \(omitted)건 생략됨 — 필터를 좁히면 전부 보입니다)"
        }

        return WikiDigest(
            text: body,
            hash: digest(of: body),
            matched: lines.count,
            total: total,
            characters: body.count
        )
    }

    /// `- [[제목]] · 진행중 · 버그 · 중간 · web·electron · minsuRob · 2026-07-09 · 요약`
    ///
    /// `[[…]]` because that is the vault's own link syntax and the basename is its
    /// identity key -- a title written this way is one the `wiki_read` tool can
    /// resolve, and one a person can paste straight into Obsidian.
    public static func line(for page: WikiPage, includeSummary: Bool) -> String {
        var fields = [
            "[[\(page.basename)]]",
            dash(page.status),
            dash(page.category),
            dash(page.priority),
            // Same joiner the vault's own indexer uses for list-valued areas.
            page.areas.isEmpty ? "-" : page.areas.joined(separator: "·"),
            dash(page.assignee),
            dash(page.updated)
        ]
        if includeSummary, !page.summary.isEmpty { fields.append(page.summary) }
        return "- " + fields.joined(separator: " · ")
    }

    /// A human-readable one-liner of what is switched on, used in the digest header,
    /// the setup row, and the options window's preview -- one description, so the
    /// three cannot drift apart.
    public static func describe(_ filter: WikiFilter) -> String {
        var parts: [String] = []
        func add(_ label: String, _ values: Set<String>) {
            guard !values.isEmpty else { return }
            let shown = values.sorted().map { $0.isEmpty ? "미지정" : $0 }
            parts.append("\(label)=\(shown.joined(separator: "·"))")
        }
        add("유형", filter.types)
        add("상태", filter.statuses)
        add("분류", filter.categories)
        add("영역", filter.areas)
        add("우선순위", filter.priorities)
        add("담당", filter.assignees)
        if !filter.titleContains.isEmpty { parts.append("검색=\(filter.titleContains)") }
        if let stale = filter.staleDays { parts.append("정체≥\(stale)일") }
        return parts.isEmpty ? "전체" : parts.joined(separator: " · ")
    }

    static func dash(_ value: String) -> String { value.isEmpty ? "-" : value }

    static func digest(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
