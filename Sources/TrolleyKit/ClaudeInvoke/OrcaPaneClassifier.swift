import Foundation

/// Who is home: a faithful Swift port of `copy-chat.py`'s `classify()`, kept
/// to exactly the same rules so a pane this reads as idle is the same pane
/// copy-chat itself would offer.
///
/// What did *not* come along is copy-chat's session-transcript retracing --
/// the anchor-matching against `~/.claude/projects/*.jsonl` that lets it
/// restore a conversation into the target pane. This module sends whatever a
/// person typed into trolley's own prompt box, not a replayed conversation,
/// so there is no conversation to retrace and nothing here reads a
/// transcript at all.
public enum OrcaPaneKind: String {
    case claudeIdle = "claude-idle"
    case claudeBusy = "claude-busy"
    case claudeDraft = "claude-draft"
    case shellDev = "shell-dev"
}

public enum OrcaPaneClassifier {
    static let claudeMarkers = [
        "bypass permissions", "/clear to save", "Tackle your toughest work",
        "shift+tab to cycle", "esc to interrupt"
    ]
    static let busyMarkers = ["esc to interrupt", "Retrying in", "Waiting…", "Called "]
    static let inputZoneLines = 10
    static let busyTimerPattern = #"\((?:\d+m\s*)?\d+s\s*·"#
    /// Glyphs a Claude Code TUI draws around its own chrome -- stripped off a
    /// candidate draft line the same way copy-chat.py's `TUI_GLYPHS` does, so
    /// a bare prompt box (`❯` with nothing typed) does not read as a draft.
    static let tuiGlyphs = CharacterSet(charactersIn: "⏺⎿✻✳❯│┌┐└┘├┤┬┴┼╭╮╰╯─═▌▐█▘▝⠐⠈⠠ ")

    /// - Parameters:
    ///   - tail: the pane's most recent screen lines, oldest first -- what
    ///     `orca terminal read --json` returns as `result.terminal.tail`.
    ///   - title: the pane's tab title. Some Claude Code panes carry "Claude
    ///     Code" in the title even when a marker string has scrolled out of
    ///     the tail window; copy-chat.py checks both, so this does too.
    public static func classify(tail: [String], title: String) -> (kind: OrcaPaneKind, draft: String) {
        let joined = tail.joined(separator: " ")
        let zone = Array(tail.suffix(inputZoneLines))
        let zoneJoined = zone.joined(separator: " ")

        let isClaude = claudeMarkers.contains { joined.contains($0) } || title.contains("Claude Code")
        guard isClaude else { return (.shellDev, "") }

        // busy·draft 판정은 화면 끝부분에서만 한다 -- 스크롤백 위쪽의 지난 턴 흔적을
        // 훑으면 유휴 창이 영원히 busy 로 오분류된다 (copy-chat.py 의 같은 이유).
        let hasBusyMarker = busyMarkers.contains { zoneJoined.contains($0) }
        let hasBusyTimer = zoneJoined.range(of: busyTimerPattern, options: .regularExpression) != nil
        if hasBusyMarker || hasBusyTimer { return (.claudeBusy, "") }

        for line in zone.reversed() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("❯") else { continue }
            let draft = String(trimmed.dropFirst())
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: tuiGlyphs)
                .trimmingCharacters(in: .whitespaces)
            return draft.isEmpty ? (.claudeIdle, "") : (.claudeDraft, draft)
        }
        return (.claudeIdle, "")
    }
}
