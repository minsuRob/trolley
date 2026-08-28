import Foundation

/// Sends a prompt to whichever idle Claude Code pane orca is holding --
/// `list`, classify each candidate with `OrcaPaneClassifier`, `send` to the
/// first (or only, if pinned) one that comes back idle.
public struct OrcaDispatchDeliverer: ClaudeInvokeDeliverer {
    public let method: ClaudeInvokeMethod = .orca

    private let orcaExecutable: () -> String?
    private let confirmBeforeSend: () -> Bool
    private let pinnedHandle: () -> String
    private let run: (String, [String]) -> (exitCode: Int32, output: String)

    public init(
        orcaExecutable: @escaping () -> String? = { OrcaCLI.locate() },
        confirmBeforeSend: @escaping () -> Bool = { ClaudeInvokeSettings.orcaConfirmBeforeSend },
        pinnedHandle: @escaping () -> String = { ClaudeInvokeSettings.orcaTargetHandle },
        run: @escaping (String, [String]) -> (exitCode: Int32, output: String) = OrcaCLI.run
    ) {
        self.orcaExecutable = orcaExecutable
        self.confirmBeforeSend = confirmBeforeSend
        self.pinnedHandle = pinnedHandle
        self.run = run
    }

    public func deliver(prompt: String, confirm: @escaping (String) -> Bool) -> ClaudeInvokeResult {
        guard let orca = orcaExecutable() else {
            return ClaudeInvokeResult(method: .orca, success: false, message: "orca 명령을 찾지 못했습니다.")
        }

        let (listCode, listOutput) = run(orca, ["terminal", "list", "--json"])
        guard listCode == 0, let terminals = OrcaCLI.parseTerminals(listOutput) else {
            return ClaudeInvokeResult(method: .orca, success: false, message: "orca 창 목록을 읽지 못했습니다.")
        }
        guard !terminals.isEmpty else {
            return ClaudeInvokeResult(method: .orca, success: false, message: "orca 로 열린 창이 없습니다.")
        }

        let pinned = pinnedHandle()
        let candidates = pinned.isEmpty ? terminals : terminals.filter { $0.handle == pinned }
        guard !candidates.isEmpty else {
            return ClaudeInvokeResult(
                method: .orca, success: false, message: "지정한 창(\(pinned))을 찾을 수 없습니다."
            )
        }

        var target: OrcaCLI.Terminal?
        for terminal in candidates {
            let (readCode, readOutput) = run(
                orca, ["terminal", "read", "--terminal", terminal.handle, "--limit", "25", "--json"]
            )
            guard readCode == 0, let tail = OrcaCLI.parseTail(readOutput) else { continue }
            let (kind, _) = OrcaPaneClassifier.classify(tail: tail, title: terminal.title)
            if kind == .claudeIdle {
                target = terminal
                break
            }
        }

        guard let target else {
            return ClaudeInvokeResult(method: .orca, success: false, message: "유휴 상태인 클로드 창이 없습니다.")
        }

        if confirmBeforeSend() {
            let ok = confirm("다음 창으로 보냅니다:\n\(target.title)\n(\(target.handle))")
            guard ok else {
                return ClaudeInvokeResult(method: .orca, success: false, message: "취소했습니다.")
            }
        }

        let (sendCode, sendOutput) = run(
            orca, ["terminal", "send", "--terminal", target.handle, "--text", prompt, "--enter"]
        )
        guard sendCode == 0 else {
            return ClaudeInvokeResult(
                method: .orca, success: false,
                message: "전송 실패 — \(sendOutput.suffix(200))"
            )
        }
        return ClaudeInvokeResult(method: .orca, success: true, message: "\(target.title) 로 전송했습니다.")
    }
}
