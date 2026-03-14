import Foundation

/// Google Gemini CLI 어댑터.
/// TODO: Gemini CLI의 실제 TUI 패턴에 맞게 구현 필요.
struct GeminiAdapter: CLIAdapter {
    let name = "Gemini"
    let modelId = "gemini"

    let defaultBinaryPaths = [
        "/usr/local/bin/gemini",
        "/opt/homebrew/bin/gemini",
        "~/.npm-global/bin/gemini",
        "~/.local/bin/gemini",
    ]
    let defaultBinaryName = "gemini"

    let exitCommand = "/exit"
    let readySignal = ">"  // TODO: Gemini CLI의 실제 ready 신호 확인 필요
    let processingSignal: String? = nil

    func buildCommand(binaryPath: String, args: [String], autoApprove: Bool) -> String {
        var cmd = binaryPath
        if autoApprove {
            cmd += " -y"
        }
        if !args.isEmpty {
            cmd += " " + args.joined(separator: " ")
        }
        return cmd
    }

    func cleanResponse(_ screenText: String) -> String {
        var cleaned = screenText.replacingOccurrences(of: "\u{0000}", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\u{007F}", with: "")

        let lines = cleaned.components(separatedBy: "\n")
        let result = lines
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
