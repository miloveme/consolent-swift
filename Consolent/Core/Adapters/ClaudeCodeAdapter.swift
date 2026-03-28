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

    /// Claude Code는 Agent SDK를 통한 headless 모드를 지원한다.
    let supportsSDKMode = true

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
        // Step 1: Null 문자 → 공백 변환 (SwiftTerm wide char 패딩 + 커서 이동 빈 셀)
        // \0을 공백으로 치환해야 단어 사이 띄어쓰기가 보존된다.
        // CJK 패딩 공백은 Step 4의 CJKSpacingFix에서 처리.
        var cleaned = screenText.replacingOccurrences(of: "\u{0000}", with: " ")
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

            // ── 사용자 입력 시작 (❯ / › 프롬프트) ──
            // TUI chrome 필터보다 먼저 체크 (프롬프트 문자가 필터에 매칭되지 않도록)
            // NBSP(\u{00A0})가 공백 대신 들어오는 경우도 처리
            // 주의: 빈 프롬프트(❯ 만)는 ready 상태 — 응답을 초기화하면 안 됨
            if trimmed.hasPrefix("❯") || trimmed.hasPrefix("›") {
                let afterPrompt = trimmed.dropFirst()
                let hasContent = !afterPrompt.trimmingCharacters(in: .whitespaces).isEmpty
                if hasContent && (afterPrompt.first == " " || afterPrompt.first == "\u{00A0}") {
                    // 새 턴 (프롬프트 뒤에 실제 텍스트 있음) → 이전 응답 버리고 사용자 입력 구간 진입
                    responseLines = []
                    phase = 1
                    continue
                }
                // 빈 프롬프트 (❯ 만) — ready 상태, 줄만 스킵
                if !hasContent {
                    continue
                }
            }

            // ── 어시스턴트 응답 시작 (⏺ 마커) ──
            // TUI chrome 필터보다 먼저 체크해야 함!
            // 응답 내용에 "is not in", ▶ 등 TUI chrome 패턴이 포함될 수 있기 때문.
            if trimmed.hasPrefix("⏺") {
                phase = 2

                // TUI 도구 사용 표시 제거
                var stripped = trimmed.replacingOccurrences(of: "^⏺\\s*", with: "", options: .regularExpression)
                // (ctrl+o to expand) 등 TUI 확장 힌트만 텍스트에서 제거 (줄 자체는 유지)
                stripped = stripped.replacingOccurrences(
                    of: "\\s*\\(ctrl\\+[a-z]\\s+to\\s+expand\\)",
                    with: "", options: .regularExpression
                )
                // thinking 인디케이터 필터 (스피너 + 랜덤 단어, thinking effort 등)
                if Self.isThinkingIndicator(stripped) {
                    continue
                }
                // 도구 사용 표시 필터: Write(...), Bash(...), Read(...) 등
                if Self.isToolInvocation(stripped) {
                    continue
                }
                // TUI chrome 패턴이 ⏺ 뒤에 붙은 경우
                if Self.matchesTUIChrome(stripped) {
                    continue
                }
                // 구분선이 ⏺ 뒤에 붙은 경우 (TUI 렌더링 잔해)
                if stripped.hasPrefix("───") || stripped.hasPrefix("━━━")
                    || stripped.allSatisfy({ $0 == "─" || $0 == "━" }) {
                    continue
                }
                if !stripped.isEmpty {
                    responseLines.append(stripped)
                }
                continue
            }

            // ── 도구 출력 줄 (⎿ 접두사) — 모든 phase에서 필터 ──
            // Claude Code가 도구 실행 결과를 ⎿ 로 표시
            // 예: "⎿  $ ls /path", "⎿  Wrote 441 lines to file", "⎿  Tip: Use /btw..."
            if trimmed.hasPrefix("⎿") {
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
        text = CJKSpacingFix.fixCJKSpacing(text)

        return text
    }

    // MARK: - Error Detection

    /// 화면 텍스트에서 API 에러를 감지한다.
    /// "api error"는 matchesTUIChrome()에서 TUI chrome으로 필터링되므로,
    /// cleanResponse()가 빈 응답을 반환할 때 이 메서드로 에러 메시지를 복구한다.
    func detectError(_ screenText: String) -> String? {
        let lines = screenText.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().contains("api error") {
                return trimmed
            }
        }
        return nil
    }

    // MARK: - Private Helpers

    private static func isBoxBorderLine(_ text: String) -> Bool {
        let boxChars: Set<Character> = ["│", "║", "┃", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼"]
        if let first = text.first, boxChars.contains(first) { return true }
        if let last = text.last, boxChars.contains(last) { return true }
        return false
    }

    /// Claude Code thinking 인디케이터 감지.
    /// 스피너 문자로 시작하거나 "(thinking with" 패턴을 포함하는 줄.
    /// 예: "✻ Discombobulating… (thinking with high effort)"
    ///     "· (thinking with standard effort)"
    static func isThinkingIndicator(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        // 스피너 문자로 시작하는 줄
        let spinnerChars: Set<Character> = [
            "✳", "✶", "✻", "✽", "✢", "·", "◉", "○", "◍", "◎", "●",
            "◐", "◑", "◒", "◓", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
        ]
        if let first = trimmed.first, spinnerChars.contains(first) { return true }

        // "thinking with high/standard effort" 포함 (괄호 유무 모두)
        if trimmed.contains("thinking with high effort") { return true }
        if trimmed.contains("thinking with standard effort") { return true }

        return false
    }

    /// 도구 사용 표시 줄 감지.
    /// Claude Code가 도구를 실행할 때 표시하는 줄:
    ///   "Write(maze/index.html)", "Bash(open /path)", "Read(file.txt)" 등
    /// 때로는 뒤에 TUI 잔해가 붙기도 함:
    ///   "Write(maze/index.html)ontinue or claude --resume..."
    private static func isToolInvocation(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Tool(args) 패턴 — 대문자로 시작하는 단어 + 괄호
        if let regex = try? NSRegularExpression(pattern: "^[A-Z][a-zA-Z]*\\(.+\\)", options: []) {
            let range = NSRange(trimmed.startIndex..., in: trimmed)
            if regex.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
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
        // 주의: 응답 내용에도 나올 수 있는 패턴은 포함하지 않는다.
        // 예: "is not in"(일반 영어 표현) 등은 제외.
        let quickPatterns = [
            "esc to interrupt", "esc to cancel",  // 처리 중 표시
            "? for shortcuts",                     // 준비 상태 표시
            "api error",
            "bypass permissions", "native installation",
            "shift+tab", "to cycle",
            "thinking with high effort",    // thinking effort 표시
            "thinking with standard effort",
            "ctrl+o to expand",        // 도구 사용 확장 힌트
            "ctrl+r to expand",        // 읽기 확장 힌트
            "running…", "running...",  // 도구 실행 상태
            "(no output)",             // 도구 출력 없음
            "baked for",               // Claude Code 실행 시간
            "thought for",             // thinking 시간
            "claude --resume",         // TUI 세션 안내
            "tip: use /",              // Claude 팁
        ]
        for pattern in quickPatterns {
            if lowered.contains(pattern) { return true }
        }

        // 상태바 삼각형 마커 (다양한 유니코드 변형)
        // ⏵ (U+23F5), ▶ (U+25B6), ► (U+25BA), ⏸ (U+23F8), ▸ (U+25B8)
        // 줄이 이 문자로 시작하면 TUI 상태바로 판단 (응답 중간의 ▶ 등은 보호)
        let statusBarChars: Set<Character> = ["⏵", "▶", "►", "⏸", "▸", "⏩"]
        if let first = text.first, statusBarChars.contains(first) {
            return true
        }

        // 스피너/thinking 인디케이터 줄
        if isThinkingIndicator(text) {
            return true
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
            "^\\d+\\.?\\d*[kK]?\\s+tokens?",   // "3.1k tokens" (trailing 허용)
            "^\\d+\\s+tool\\s+use",
            "^Read\\s+\\d+\\s+file",            // "Read 1 file (ctrl+o to expand)"
            "^Reading\\s+\\d+\\s+file",          // "Reading 1 file…"
            "^Wrote\\s+\\d+\\s+lines?",          // "Wrote 441 lines to maze/index.html"
            "^Write\\(.+\\)",                    // "Write(maze/index.html)"
            "^Bash\\(.+\\)",                     // "Bash(open /path/to/file)"
            "^\\s{2,}\\d{1,5}\\s{1,2}\\S",       // 줄번호 파일 미리보기: "     1 <!DOCTYPE html>"
            "^…\\s*\\+\\d+\\s+lines?",           // "…+431 lines (ctrl+o to expand)"
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
