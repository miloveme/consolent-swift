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
        // Step 1: Null 문자 제거 (SwiftTerm wide char 패딩)
        var cleaned = screenText.replacingOccurrences(of: "\u{0000}", with: "")
        cleaned = cleaned.replacingOccurrences(of: "\u{007F}", with: "")

        let lines = cleaned.components(separatedBy: "\n")

        // Step 2: 상태 머신으로 응답 본문만 추출
        //   - phase 0: 초기 (환영 화면, 이전 대화 등)
        //   - phase 1: 사용자 입력 감지됨 (❯/› 이후) → ⏺ 나올 때까지 스킵
        //   - phase 2: 어시스턴트 응답 수집 중 (⏺ 이후)
        var responseLines: [String] = []
        var phase = 0  // 0=초기, 1=사용자입력구간, 2=어시스턴트응답

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 빈 줄
            if trimmed.isEmpty {
                if phase == 2 { responseLines.append("") }
                continue
            }

            // TUI chrome / 상태바 — 모든 phase에서 필터
            if Self.matchesTUIChrome(trimmed) {
                continue
            }

            // 박스 테두리 줄 (환영 화면)
            if phase != 2 && Self.isBoxBorderLine(trimmed) {
                continue
            }

            // 구분선 (───)
            if trimmed.hasPrefix("───") || trimmed.hasPrefix("━━━") || trimmed.allSatisfy({ $0 == "─" || $0 == "━" }) {
                continue
            }

            // 스피너
            if Self.isSpinnerOnlyLine(trimmed) {
                continue
            }

            // 프롬프트만 있는 줄
            if trimmed == "›" || trimmed == "❯" || trimmed == ">" || trimmed == "$" {
                continue
            }

            // ── 사용자 입력 시작 (❯ / › 프롬프트) ──
            if trimmed.hasPrefix("❯ ") || trimmed.hasPrefix("› ") {
                // 새 턴 → 이전 응답 버리고 사용자 입력 구간 진입
                responseLines = []
                phase = 1
                continue
            }

            // ── 어시스턴트 응답 시작 (⏺ 마커) ──
            if trimmed.hasPrefix("⏺") {
                phase = 2

                // TUI 도구 사용 표시 제거
                if trimmed.range(of: "⏺\\s+(Read|Wrote|Ran|Created|Updated|Deleted|Searched|Listed)\\s+.*\\(ctrl\\+", options: .regularExpression) != nil {
                    continue
                }
                let stripped = trimmed.replacingOccurrences(of: "^⏺\\s*", with: "", options: .regularExpression)
                if !stripped.isEmpty {
                    responseLines.append(stripped)
                }
                continue
            }

            // phase 1: 사용자 입력 구간 → 스킵 (JSON 메타데이터, 에코된 입력 등)
            if phase == 1 {
                continue
            }

            // phase 2: 어시스턴트 응답 수집
            if phase == 2 {
                responseLines.append(line)
            }
        }

        // Step 3: 연속 빈 줄 정리
        var result: [String] = []
        var lastWasEmpty = false
        for line in responseLines {
            let isEmpty = line.trimmingCharacters(in: .whitespaces).isEmpty
            if isEmpty {
                if !lastWasEmpty { result.append("") }
                lastWasEmpty = true
            } else {
                let trimmedTrailing = line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                result.append(trimmedTrailing)
                lastWasEmpty = false
            }
        }

        var text = result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)

        // Step 4: CJK wide character 간격 보정
        // SwiftTerm이 wide char 뒤에 padding space를 넣는 경우 제거
        text = Self.fixCJKSpacing(text)

        return text
    }

    // MARK: - Private Helpers

    /// CJK wide character 패딩 공백 제거.
    ///
    /// SwiftTerm은 wide char(2열) 뒤에 패딩 공백을 삽입한다.
    /// 터미널 버퍼에서 읽으면:
    ///   - 패딩만: CJK + 1space → 다음 문자 (예: "안 녕" → "안녕")
    ///   - 패딩 + 단어 경계: CJK + 2spaces (예: "을  다" → "을 다")
    ///
    /// 패딩 감지: CJK 문자의 50% 이상이 뒤에 공백이 있으면 패딩으로 판단.
    /// 정상 한국어 텍스트(패딩 없음)는 건드리지 않는다.
    static func fixCJKSpacing(_ text: String) -> String {
        return text.components(separatedBy: "\n")
            .map { fixCJKSpacingInLine($0) }
            .joined(separator: "\n")
    }

    private static func fixCJKSpacingInLine(_ line: String) -> String {
        let chars = Array(line)
        guard chars.count >= 3 else { return line }

        // 패딩 감지: CJK 문자 뒤에 공백이 있는 비율
        var cjkCount = 0
        var paddedCount = 0
        for i in 0..<chars.count {
            if isCJK(chars[i]) {
                cjkCount += 1
                if i + 1 < chars.count && chars[i + 1] == " " {
                    paddedCount += 1
                }
            }
        }

        // CJK가 2개 미만이거나 패딩 비율 50% 이하면 정상 텍스트 → 그대로 반환
        guard cjkCount >= 2, Double(paddedCount) / Double(cjkCount) > 0.5 else {
            return line
        }

        // CJK 문자 뒤의 패딩 공백 제거
        var result: [Character] = []
        var i = 0

        while i < chars.count {
            result.append(chars[i])

            if isCJK(chars[i]) && i + 1 < chars.count && chars[i + 1] == " " {
                if i + 2 < chars.count && chars[i + 2] == " " {
                    // 2칸 공백 (패딩 + 단어 경계) → 1칸 공백 보존
                    result.append(" ")
                    i += 3
                } else {
                    // 1칸 공백 (패딩만) → 제거
                    i += 2
                }
            } else {
                i += 1
            }
        }

        return String(result)
    }

    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x1100...0x11FF).contains(v) ||   // Hangul Jamo
               (0x2E80...0x9FFF).contains(v) ||   // CJK Radicals ~ CJK Unified Ideographs
               (0xAC00...0xD7AF).contains(v) ||   // Hangul Syllables
               (0xF900...0xFAFF).contains(v) ||   // CJK Compatibility Ideographs
               (0xFE30...0xFE4F).contains(v) ||   // CJK Compatibility Forms
               (0x3000...0x30FF).contains(v) ||   // CJK Symbols, Hiragana, Katakana
               (0x31F0...0x31FF).contains(v) ||   // Katakana Extensions
               (0xFF00...0xFFEF).contains(v)      // Fullwidth Forms
    }

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
        let quickPatterns = [
            "esc to interrupt", "? for shortcuts", "api error",
            "bypass permissions", "native installation",
            "is not in", "shift+tab", "to cycle",
        ]
        for pattern in quickPatterns {
            if lowered.contains(pattern) { return true }
        }

        // 상태바 삼각형 마커 (다양한 유니코드 변형)
        // ⏵ (U+23F5), ▶ (U+25B6), ► (U+25BA), ⏸ (U+23F8), ▸ (U+25B8)
        let statusBarChars: [Character] = ["⏵", "▶", "►", "⏸", "▸", "⏩"]
        for ch in statusBarChars {
            if text.contains(ch) { return true }
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
            "^\\d+\\.?\\d*[kK]?\\s+tokens?.*\\d+\\.?\\d*[kK]?\\s+remaining",
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
