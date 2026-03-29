import Foundation

/// Google Gemini CLI 어댑터.
/// Gemini CLI의 TUI 패턴, 완료 감지, 응답 파싱 로직을 캡슐화한다.
struct GeminiAdapter: CLIAdapter {
    let name = "Gemini"
    let modelId = "gemini"

    /// Gemini CLI은 stream-json 모드를 지원한다.
    var supportsGeminiStreamMode: Bool { true }

    let defaultBinaryPaths = [
        "/usr/local/bin/gemini",
        "/opt/homebrew/bin/gemini",
        "~/.npm-global/bin/gemini",
        "~/.local/bin/gemini",
    ]
    let defaultBinaryName = "gemini"

    let exitCommand = "/quit"

    /// Gemini CLI ready 신호: 입력 필드 플레이스홀더.
    /// 입력 대기 시 나타나고, 처리 중에는 사라진다.
    let readySignal = "Type your message"

    /// Gemini CLI 처리 중 신호: 처리 중에 esc to cancel 또는 thinking 스피너 표시
    let processingSignal: String? = "esc\\s+to\\s+cancel"

    /// Gemini 응답 완료 감지:
    /// screenBuffer = 터미널 하단 5줄.
    /// 응답 완료 후 Gemini는 입력 영역(▀▀▀ ~ ▄▄▄)과 상태바를 하단에 다시 그린다.
    /// ✦ 마커는 위쪽으로 밀려 하단 5줄에 없을 수 있으므로 사용하지 않는다.
    func isResponseComplete(screenBuffer: String) -> Bool {
        // 처리 중이면 완료 아님
        let hasProcessing = screenBuffer.range(
            of: "esc\\s+to\\s+cancel",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        if hasProcessing { return false }

        // trust 다이얼로그 표시 중이면 완료 아님 (승인 대기)
        if screenBuffer.contains("Do you trust the files in this folder?")
            || screenBuffer.contains("Trust folder")
            || screenBuffer.contains("Trust parent folder") {
            return false
        }

        // 입력 필드 플레이스홀더가 보이면 = Gemini가 입력 대기 상태
        let hasInputPlaceholder = screenBuffer.contains("Type your message")
        // 플레이스홀더가 없더라도 입력 영역(▀▀▀/▄▄▄) + 상태바가 있으면 완료
        let hasModel = screenBuffer.contains("/model")
        let hasBlockBar = screenBuffer.contains("▀▀▀") || screenBuffer.contains("▄▄▄")
        return hasInputPlaceholder || (hasModel && hasBlockBar)
    }

    /// Gemini 전용 승인 패턴 — trust 다이얼로그 포함
    var approvalPatterns: [String] {
        [
            // 기본 y/n 패턴 (공통)
            "\\(y/n\\)\\s*$",
            "\\(Y/n\\)\\s*$",
            "\\[y/N\\]\\s*$",
            "\\[Y/n\\]\\s*$",
            "Do you want to proceed\\?",
            "Allow .+\\?\\s*\\(y\\)",
            "Press Enter to continue",
            // Gemini CLI trust 다이얼로그
            "Do you trust the files in this folder\\?",
            "Trust folder \\(",
        ]
    }

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

    // MARK: - Response Parsing

    func cleanResponse(_ screenText: String) -> String {
        // Step 1: Null 문자 → 공백 변환 (SwiftTerm wide char 패딩 + 커서 이동 빈 셀)
        // \0을 공백으로 치환해야 단어 사이 띄어쓰기가 보존된다.
        // CJK 패딩 공백은 Step 4의 CJKSpacingFix에서 처리.
        var cleaned = screenText.replacingOccurrences(of: "\u{0000}", with: " ")
        cleaned = cleaned.replacingOccurrences(of: "\u{007F}", with: "")

        let lines = cleaned.components(separatedBy: "\n")

        // Step 2: 상태 머신으로 응답 본문만 추출
        //   - phase 0: 초기 (ASCII art 헤더, 배너 등)
        //   - phase 1: 사용자 입력 감지됨 (> / ! / * 이후) → ✦ 나올 때까지 스킵
        //   - phase 2: 어시스턴트 응답 수집 중 (✦ 이후)
        var responseLines: [String] = []
        var phase = 0  // 0=초기, 1=사용자입력구간, 2=어시스턴트응답

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 빈 줄
            if trimmed.isEmpty {
                if phase == 2 { responseLines.append("") }
                continue
            }

            // ── 어시스턴트 응답 시작 (✦ 마커) ──
            // TUI chrome 필터보다 먼저 체크해야 함!
            // 응답 내용에 "gemini cli" 등 TUI chrome 패턴이 포함될 수 있기 때문.
            //
            // 리셋 조건:
            //   - phase 0/1 → 새 턴 시작 → responseLines 클리어
            //   - phase 2   → 같은 턴 내 연속 ✦ (tool use 후 이어지는 응답) → 누적
            // Gemini는 tool use 전후로 여러 ✦ 섹션을 생성하므로
            // 같은 턴에서는 클리어하면 스트리밍 시 이전 섹션이 소실된다.
            if trimmed.hasPrefix("✦") {
                if phase != 2 {
                    // 새 턴 시작 (phase 0 또는 1에서 전환) → 이전 응답 클리어
                    responseLines = []
                } else {
                    // 같은 턴 내 연속 ✦ (tool use 후 이어지는 응답) → 빈 줄로 구분
                    responseLines.append("")
                }
                phase = 2

                let stripped = trimmed.replacingOccurrences(of: "^✦\\s*", with: "", options: .regularExpression)
                if !stripped.isEmpty {
                    responseLines.append(stripped)
                }
                continue
            }

            // TUI chrome / 상태바 — 모든 phase에서 필터
            // "* Type your message" 등 입력 필드 플레이스홀더를 사용자 입력보다 먼저 걸러야 함
            if Self.matchesTUIChrome(trimmed) {
                continue
            }

            // ── 사용자 입력 시작 (> / ! / * 프롬프트) ──
            // TUI chrome 뒤에 배치: Gemini 입력 필드 "* Type your message"가
            // hasPrefix("* ")에 매칭되어 responseLines를 클리어하는 것을 방지
            //
            // phase 2(응답 수집 중)에서는 무시:
            //   - 응답에 마크다운 불릿("* 항목")이나 인용("> 내용")이 포함될 수 있음
            //   - 실제 새 턴은 항상 ▀▀▀ 블록바 이후에 나타남 → ▀▀▀이 phase를 0으로 리셋
            //   - 따라서 phase 0/1에서만 턴 마커로 인식해도 멀티턴이 정상 동작함
            if phase != 2 && (trimmed.hasPrefix("> ") || trimmed.hasPrefix("! ") || trimmed.hasPrefix("* ")) {
                responseLines = []
                phase = 1
                continue
            }

            // 박스 테두리 줄 (도구 표시 등)
            if Self.isBoxBorderLine(trimmed) {
                continue
            }

            // ASCII art / 블록 구분자 줄 (▀▀▀, ▄▄▄)
            // phase 2에서 만나면 응답 영역이 끝나고 UI 영역 시작
            if Self.isAsciiArtLine(trimmed) {
                if phase == 2 { phase = 0 }
                continue
            }

            // 구분선 (───) — phase 2에서 만나면 응답 영역 끝 (TUI chrome 영역 시작)
            if trimmed.hasPrefix("───") || trimmed.hasPrefix("━━━") || trimmed.allSatisfy({ $0 == "─" || $0 == "━" }) {
                if phase == 2 { phase = 0 }
                continue
            }

            // 스피너
            if Self.isSpinnerOnlyLine(trimmed) {
                continue
            }

            // 프롬프트만 있는 줄
            if trimmed == ">" || trimmed == "!" || trimmed == "*" || trimmed == "$" {
                continue
            }

            // 도구 상태 줄 (✓ ToolName, ⊷ ToolName 등)
            if Self.isToolStatusLine(trimmed) {
                continue
            }

            // phase 1: 사용자 입력 구간 → 스킵
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
        text = CJKSpacingFix.fixCJKSpacing(text)

        return text
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

    /// ASCII art 블록 문자로 이루어진 헤더 줄 감지.
    /// Gemini CLI는 시작 시 블록 문자로 된 로고를 표시한다.
    private static func isAsciiArtLine(_ text: String) -> Bool {
        let blockChars: Set<Character> = ["█", "░", "▒", "▓", "▝", "▜", "▗", "▟", "▀", "▄", "▌", "▐", "▖", "▘", "▛", "▙", "▚", "▞"]
        let nonSpaceChars = text.filter { !$0.isWhitespace }
        guard !nonSpaceChars.isEmpty else { return false }
        let blockCount = nonSpaceChars.filter { blockChars.contains($0) }.count
        return Double(blockCount) / Double(nonSpaceChars.count) > 0.5
    }

    /// 도구 상태 줄 감지 (✓ Shell, ⊷ ReadFile 등).
    private static func isToolStatusLine(_ text: String) -> Bool {
        let statusSymbols: [Character] = ["✓", "⊷", "✗", "✕"]
        guard let first = text.first else { return false }
        if statusSymbols.contains(first) && text.count > 2 && text.dropFirst().first == " " {
            return true
        }
        // "o ToolName" 또는 "x ToolName" 패턴 (단일 문자 + 공백 + 대문자 시작)
        if (first == "o" || first == "x" || first == "?") && text.count > 2 {
            let afterSpace = text.dropFirst(2)
            if text.dropFirst().first == " ", let firstAfter = afterSpace.first, firstAfter.isUppercase {
                return true
            }
        }
        return false
    }

    private static func matchesTUIChrome(_ text: String) -> Bool {
        let lowered = text.lowercased()
        // 주의: 응답 내용에도 나올 수 있는 패턴은 포함하지 않는다.
        // 예: "gemini cli"(자기소개), "code assist in"(기능 설명) 등은 제외.
        let quickPatterns = [
            "esc to cancel", "? for shortcuts", "press tab twice",
            "type your message", "shift+tab",
            "loaded cached credentials", "no sandbox",
            "yolo ctrl+", "auto-accept ctrl+", "plan ctrl+",
            "logged in with",
        ]
        for pattern in quickPatterns {
            if lowered.contains(pattern) { return true }
        }

        // 승인 모드 표시
        let modeIndicators = [
            "YOLO mode", "yolo mode",
            "auto-accept edits", "Auto-accept edits",
            "Plan mode", "plan mode",
            "Shell mode", "shell mode",
        ]
        for indicator in modeIndicators {
            if text.contains(indicator) { return true }
        }

        // 종료 경고
        if lowered.contains("press ctrl+c again") || lowered.contains("press ctrl+d again") {
            return true
        }

        // 상태 표시 패턴
        let statusPatterns = [
            "I'm Feeling Lucky", "Shipping awesomeness",
            "Reticulating splines",
        ]
        for pattern in statusPatterns {
            if text.contains(pattern) { return true }
        }

        // 토큰 카운트, 컨텍스트 정보, 컨텍스트 항목
        let regexPatterns = [
            "^\\d+\\.?\\d*[kK]?\\s+tokens?$",
            "^\\d+\\s+tool\\s+use",
            "^\\d+\\.?\\d*[kK]?\\s+tokens?.*\\d+\\.?\\d*[kK]?\\s+remaining",
            "^model:\\s+",
            "^context:\\s+",
            "^-\\s+\\d+\\s+",  // - 1 GEMINI.md file, - 2 skills 등 컨텍스트 항목
            "/model\\s+",                                              // /model Auto (Gemini 3)
            "/auth$",                                                   // /auth
            "/upgrade$",                                                // /upgrade
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
