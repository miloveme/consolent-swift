import Foundation

/// Claude Code CLI 어댑터.
/// Claude Code의 TUI 패턴, 완료 감지, 응답 파싱 로직을 캡슐화한다.
struct ClaudeCodeAdapter: CLIAdapter {
    let name = "Claude Code"
    let modelId = "claude-code"

    let defaultBinaryPaths = [
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
        "~/.npm-global/bin/claude",
        "~/.local/bin/claude",
        "~/.claude/local/claude",
    ]
    let defaultBinaryName = "claude"

    let exitCommand = "/exit"
    let readySignal = "? for shortcuts"
    let processingSignal: String? = "esc\\s+to\\s+interrupt"

    func buildCommand(binaryPath: String, args: [String], autoApprove: Bool) -> String {
        var cmd = binaryPath
        if autoApprove {
            cmd += " --dangerously-skip-permissions"
        }
        if !args.isEmpty {
            cmd += " " + args.joined(separator: " ")
        }
        return cmd
    }

    // MARK: - Response Parsing

    func cleanResponse(_ screenText: String) -> String {
        // Step 1: Null 문자 → 공백 대체 (SwiftTerm 빈 셀이 공백 역할)
        var cleaned = screenText.replacingOccurrences(of: "\u{0000}", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\u{007F}", with: "")

        let lines = cleaned.components(separatedBy: "\n")

        // Step 2: 환영 화면 박스 & TUI chrome 제거, 응답 본문 추출
        var responseLines: [String] = []
        var foundResponseStart = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty {
                if foundResponseStart { responseLines.append("") }
                continue
            }

            // 박스 테두리 줄 — 응답 시작 전에만 필터링 (환영 화면)
            if !foundResponseStart && Self.isBoxBorderLine(trimmed) {
                continue
            }

            // 구분선 (───)
            if trimmed.hasPrefix("───") || trimmed.hasPrefix("━━━") || trimmed.allSatisfy({ $0 == "─" || $0 == "━" }) {
                continue
            }

            // 프롬프트만 있는 줄
            if trimmed == "›" || trimmed == "❯" || trimmed == ">" || trimmed == "$" {
                continue
            }

            // 사용자 입력 줄 — 매번 리셋하여 마지막 턴만 남긴다
            if trimmed.hasPrefix("❯ ") || trimmed.hasPrefix("› ") {
                responseLines = []
                foundResponseStart = true
                continue
            }

            // ⏺ 마커로 시작하면 응답 시작
            if !foundResponseStart && trimmed.hasPrefix("⏺") {
                foundResponseStart = true
            }

            // 푸터 / 상태 텍스트
            if Self.matchesTUIChrome(trimmed) {
                continue
            }

            // 스피너 문자만 있는 줄
            if Self.isSpinnerOnlyLine(trimmed) {
                continue
            }

            if foundResponseStart {
                if trimmed.hasPrefix("⏺") {
                    // TUI 도구 사용 표시 제거
                    if trimmed.range(of: "⏺\\s+(Read|Wrote|Ran|Created|Updated|Deleted|Searched|Listed)\\s+.*\\(ctrl\\+", options: .regularExpression) != nil {
                        continue
                    }
                    let stripped = trimmed.replacingOccurrences(of: "^⏺\\s*", with: "", options: .regularExpression)
                    responseLines.append(stripped)
                } else {
                    responseLines.append(line)
                }
            }
        }

        // 연속 빈 줄 정리
        var result: [String] = []
        var lastWasEmpty = false
        for line in responseLines {
            let isEmpty = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty {
                if !lastWasEmpty { result.append("") }
                lastWasEmpty = true
            } else {
                result.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
                lastWasEmpty = false
            }
        }

        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Private Helpers

    private static func isBoxBorderLine(_ text: String) -> Bool {
        let boxChars: Set<Character> = ["│", "║", "┃", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼"]
        if let first = text.first, boxChars.contains(first) { return true }
        if let last = text.last, boxChars.contains(last) { return true }
        return false
    }

    private static func isSpinnerOnlyLine(_ text: String) -> Bool {
        let spinnerChars: Set<Character> = [
            "✳", "✶", "✻", "✽", "✢", "·", "◉", "○", "◍", "◎", "●",
            "◐", "◑", "◒", "◓", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
        ]
        let nonSpaceChars = text.filter { !$0.isWhitespace }
        return !nonSpaceChars.isEmpty && nonSpaceChars.allSatisfy({ spinnerChars.contains($0) })
    }

    private static func matchesTUIChrome(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let quickPatterns = ["esc to interrupt", "? for shortcuts", "api error"]
        for pattern in quickPatterns {
            if lowered.contains(pattern) { return true }
        }

        let statusPatterns = [
            "Streaming…", "Flowing…", "Thinking…", "Processing…",
            "Reading…", "Writing…", "Searching…", "Analyzing…",
            "Razzle-dazzling…", "Razzle-dazzling...",
        ]
        for pattern in statusPatterns {
            if text.contains(pattern) { return true }
        }

        let regexPatterns = [
            "^\\d+\\.?\\d*[kK]?\\s+tokens?$",
            "^\\d+\\s+tool\\s+use",
        ]
        for pattern in regexPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(text.startIndex..., in: text)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }

        return false
    }
}
