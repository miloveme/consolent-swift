import Foundation

/// OpenAI Codex CLI 어댑터.
/// TODO: Codex CLI의 실제 TUI 패턴에 맞게 구현 필요.
struct CodexAdapter: CLIAdapter {
    let name = "Codex"
    let modelId = "codex"

    let defaultBinaryPaths = [
        "/usr/local/bin/codex",
        "/opt/homebrew/bin/codex",
        "~/.npm-global/bin/codex",
        "~/.local/bin/codex",
    ]
    let defaultBinaryName = "codex"

    let exitCommand = "/exit"
    let readySignal = ">"  // TODO: Codex CLI의 실제 ready 신호 확인 필요
    let processingSignal: String? = nil

    func buildCommand(binaryPath: String, args: [String], autoApprove: Bool) -> String {
        var cmd = binaryPath
        if autoApprove {
            cmd += " --full-auto"
        }
        if !args.isEmpty {
            cmd += " " + args.joined(separator: " ")
        }
        return cmd
    }

    func cleanResponse(_ screenText: String) -> String {
        // 기본 정리: null 문자 제거 + trailing 공백 제거
        var cleaned = screenText.replacingOccurrences(of: "\u{0000}", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\u{007F}", with: "")

        let lines = cleaned.components(separatedBy: "\n")
        let result = lines
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
