import Foundation

/// OpenAI Codex CLI 어댑터.
/// Codex CLI(Rust/Ratatui 기반)의 TUI 패턴, 완료 감지, 응답 파싱 로직을 캡슐화한다.
///
/// Codex TUI 구조:
///   › 사용자 입력                          ← 사용자 입력 (› 프롬프트)
///   • 응답 첫 줄                           ← 어시스턴트 응답 (• bullet)
///     응답 계속...                          ← 연속 줄 (2칸 들여쓰기)
///   • Ran `ls -la`                         ← 도구 실행 (✓ 성공 / ✗ 실패)
///     └ output...                          ← 도구 출력
///   ? for shortcuts        100% context    ← 하단 상태바
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

    /// 바이너리 경로 탐색 — nvm/fnm 설치 경로 추가 탐색.
    /// macOS 앱(.app)에서 실행 시 nvm/fnm이 로드되지 않아 `which codex`가 실패할 수 있으므로
    /// Node 버전 매니저별 경로를 직접 탐색한다.
    func findBinaryPath() -> String {
        let fm = FileManager.default

        // 1. 하드코딩된 경로
        for path in defaultBinaryPaths {
            let expanded = NSString(string: path).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        // 2. nvm 설치 경로 탐색 (최신 버전 우선)
        let nvmDir = NSString(string: "~/.nvm/versions/node").expandingTildeInPath
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for version in versions.sorted().reversed() {
                let path = "\(nvmDir)/\(version)/bin/codex"
                if fm.isExecutableFile(atPath: path) {
                    return path
                }
            }
        }

        // 3. fnm 설치 경로 탐색 (최신 버전 우선)
        //    fnm은 multishell(PID 기반 임시 경로)을 사용하므로 하드코딩 불가.
        //    대신 fnm이 관리하는 node-versions에서 고정 경로를 탐색한다.
        //    실제 multishell 경로는 Session의 -li 플래그로 .zshrc의 eval "$(fnm env)"가 처리.
        let fnmDirs = [
            "~/.local/share/fnm/node-versions",   // fnm 기본 경로
            "~/Library/Application Support/fnm/node-versions",  // macOS 대체 경로
        ]
        for fnmDir in fnmDirs {
            let expanded = NSString(string: fnmDir).expandingTildeInPath
            if let versions = try? fm.contentsOfDirectory(atPath: expanded) {
                for version in versions.sorted().reversed() {
                    let path = "\(expanded)/\(version)/installation/bin/codex"
                    if fm.isExecutableFile(atPath: path) {
                        return path
                    }
                }
            }
        }

        // 4. fnm aliases (default, lts 등)
        let fnmAliasDir = NSString(string: "~/.local/share/fnm/aliases/default/bin").expandingTildeInPath
        let codexInAlias = "\(fnmAliasDir)/codex"
        if fm.isExecutableFile(atPath: codexInAlias) {
            return codexInAlias
        }

        // 5. login shell의 which 로 검색 (-li로 .zshrc 포함)
        if let resolved = resolveViaLoginShell(defaultBinaryName) {
            return resolved
        }

        return defaultBinaryName
    }

    /// login shell에서 바이너리 경로를 찾는다.
    private func resolveViaLoginShell(_ binary: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: shell)
        // -li: login + interactive. .zshrc의 PATH 설정(nvm 등)을 포함하여 탐색.
        process.arguments = ["-li", "-c", "which \(binary)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let path, !path.isEmpty, process.terminationStatus == 0 {
                return path
            }
        } catch {}

        return nil
    }

    /// Codex ready 신호: 입력 대기 시 하단 상태바에 표시.
    /// v0.114.0+에서는 "gpt-... · 96% left · ~/..." 형태.
    let readySignal = "% left"

    /// Codex 처리 중 신호: "• Working (0s • esc to interrupt)" 형태.
    /// Claude Code와 유사한 패턴.
    let processingSignal: String? = "esc\\s+to\\s+interrupt"

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

    /// Codex 승인 프롬프트 패턴.
    var approvalPatterns: [String] {
        [
            "Would you like to run the following command\\?",
            "Would you like to make the following edits\\?",
            "Continue anyway\\?\\s*\\[y/N\\]",
            "\\(y/n\\)\\s*$",
            "\\(Y/n\\)\\s*$",
            "\\[y/N\\]\\s*$",
            "Press Enter to continue",
        ]
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
        //   - phase 0: 초기 (환영 화면, Tip 등)
        //   - phase 1: 사용자 입력 감지됨 (› 이후) → • 나올 때까지 스킵
        //   - phase 2: 어시스턴트 응답 수집 중 (• 이후)
        var responseLines: [String] = []
        var lastResponseLines: [String] = []  // › 이전에 수집된 응답 백업
        var backupProcessingDetected = false   // 백업 이후 새 처리(Working/Running)가 감지됐는지
        var phase = 0  // 0=초기, 1=사용자입력구간, 2=어시스턴트응답

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 빈 줄
            if trimmed.isEmpty {
                if phase == 2 { responseLines.append("") }
                continue
            }

            // ── 사용자 입력 시작 (› 프롬프트) ──
            // TUI chrome 필터보다 먼저 체크
            // Codex는 응답 후 입력 플레이스홀더(› Find and fix...)를 표시하므로
            // 수집된 응답을 백업해두고, 이후 새 응답이 없으면 복원한다.
            // 단, 새 메시지 처리 중(• Working... → phase 2)이면 복원하지 않는다.
            if trimmed.hasPrefix("› ") {
                if phase == 2 && !responseLines.isEmpty {
                    lastResponseLines = responseLines
                    backupProcessingDetected = false  // 새 백업 시점에서 리셋
                }
                responseLines = []
                phase = 1
                continue
            }

            // ── 어시스턴트 응답 시작 (• bullet 마커) ──
            // TUI chrome 필터보다 먼저 체크해야 함!
            if trimmed.hasPrefix("•") || trimmed.hasPrefix("◦") {
                // 도구 실행 표시 필터 (• Ran, • Running, • Explored 등)
                if Self.isToolLine(trimmed) {
                    // phase 2 유지하되 도구 줄 자체는 수집하지 않음
                    if phase != 2 { phase = 2 }
                    backupProcessingDetected = true
                    continue
                }

                // 상태 표시 필터 (• Working, • Analyzing 등)
                // 상태 줄 자체는 수집하지 않지만, 새 처리가 시작됐음을 표시 (phase 2 전환).
                // 이렇게 해야 › 플레이스홀더 후 이전 응답 복원 시
                // "처리 중" 상태와 "아직 새 메시지 없음" 상태를 구분할 수 있다.
                if Self.isStatusLine(trimmed) {
                    if phase != 2 { phase = 2 }
                    backupProcessingDetected = true
                    continue
                }

                phase = 2
                let stripped = trimmed.replacingOccurrences(of: "^[•◦]\\s*", with: "", options: .regularExpression)
                if !stripped.isEmpty {
                    responseLines.append(stripped)
                }
                continue
            }

            // TUI chrome / 상태바 — 모든 phase에서 필터
            if Self.matchesTUIChrome(trimmed) {
                continue
            }

            // 도구 출력 줄 (└ prefix) — 수집하지 않음
            if trimmed.hasPrefix("└ ") || trimmed.hasPrefix("└") {
                continue
            }

            // 승인 프롬프트 UI 필터
            if Self.isApprovalUI(trimmed) {
                continue
            }

            // 박스 테두리 줄
            if Self.isBoxBorderLine(trimmed) {
                continue
            }

            // 구분선 (───)
            if trimmed.hasPrefix("───") || trimmed.hasPrefix("━━━") || trimmed.allSatisfy({ $0 == "─" || $0 == "━" }) {
                continue
            }

            // 프롬프트만 있는 줄
            if trimmed == "›" || trimmed == ">" || trimmed == "$" {
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

        // 마지막 › 이후 새 응답이 없고 새 처리도 감지되지 않았으면 (입력 플레이스홀더였음) → 이전 응답 복원.
        // 백업 이후 • Working... / • Running... 등이 감지됐으면 새 메시지 처리 중이므로 복원하지 않는다.
        // 이 조건이 없으면 연속 요청 시 이전 응답이 그대로 다시 반환되는 버그가 발생한다.
        if responseLines.isEmpty && !lastResponseLines.isEmpty && !backupProcessingDetected {
            responseLines = lastResponseLines
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

    /// 도구 실행 줄 감지 (• Ran, • Running, • Explored 등).
    private static func isToolLine(_ text: String) -> Bool {
        let toolPatterns = [
            "^[•◦]\\s+(Ran|Running|Exploring|Explored|Searching|Searched|Reading|Read|Calling|Called)\\b",
            "^[•◦]\\s+(You ran|Proposed Plan|Updated Plan)\\b",
        ]
        for pattern in toolPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        // 완료 상태 마커 (✓ ✗ ✔)
        if text.contains("✓") || text.contains("✗") || text.contains("✔") || text.contains("✕") {
            if text.range(of: "^[•◦]\\s+", options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// 상태 표시 줄 감지 (• Working, • Analyzing 등).
    private static func isStatusLine(_ text: String) -> Bool {
        let statusPatterns = [
            "^[•◦]\\s+(Working|Analyzing|Thinking|Processing)",
        ]
        for pattern in statusPatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// 승인 프롬프트 UI 줄 감지.
    private static func isApprovalUI(_ text: String) -> Bool {
        let patterns = [
            "Would you like to run",
            "Would you like to make",
            "Yes, proceed",
            "Yes, and don't ask again",
            "No, and tell Codex",
            "Press enter to confirm",
            "press esc to cancel",
        ]
        let lowered = text.lowercased()
        for pattern in patterns {
            if lowered.contains(pattern.lowercased()) { return true }
        }
        // 승인 메뉴 항목 (› 1. ... / 2. ... / 3. ...)
        if text.range(of: "^[›\\s]*\\d+\\.\\s+", options: .regularExpression) != nil {
            // 응답 내용의 번호 목록과 구분: 승인 키워드 포함 시만 필터
            if lowered.contains("proceed") || lowered.contains("don't ask") || lowered.contains("tell codex") {
                return true
            }
        }
        // 승인/거부 이력 (✔ You approved, ✗ You denied)
        if text.contains("You approved") || text.contains("You denied") {
            return true
        }
        return false
    }

    private static func isBoxBorderLine(_ text: String) -> Bool {
        let boxChars: Set<Character> = ["│", "║", "┃", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼"]
        if let first = text.first, boxChars.contains(first) { return true }
        if let last = text.last, boxChars.contains(last) { return true }
        return false
    }

    private static func matchesTUIChrome(_ text: String) -> Bool {
        let lowered = text.lowercased()

        // 하단 상태바 패턴
        let quickPatterns = [
            "? for shortcuts", "esc to interrupt",
            "shift+tab to cycle", "shift+tab",
            "context left", "context remaining",
            "% left", "/model to change",
            "ask codex to do anything",
        ]
        for pattern in quickPatterns {
            if lowered.contains(pattern) { return true }
        }

        // 모드 표시
        let modePatterns = [
            "Plan", "Pair Programming", "Execute",
            "full-auto", "Full Auto",
        ]
        // 모드 표시는 단독 줄이거나 "(shift+tab" 과 함께 올 때만
        for pattern in modePatterns {
            if text == pattern || (text.contains(pattern) && lowered.contains("shift+tab")) {
                return true
            }
        }

        // 환영 메시지 / Tip
        if lowered.hasPrefix("tip:") || lowered.hasPrefix("tip :")
            || text.contains("Welcome to Codex") {
            return true
        }

        // 토큰/컨텍스트 카운트
        let regexPatterns = [
            "^\\d+\\.?\\d*[kK]?\\s+tokens?$",
            "^\\d+%\\s+context",
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

        // 에러/경고 표시 (■ prefix)
        if text.hasPrefix("■ ") || text.hasPrefix("⚠ ") {
            return true
        }

        // 인터럽트 메시지
        if text.contains("Conversation interrupted") {
            return true
        }

        // 종료 경고
        if lowered.contains("press ctrl+c again") || lowered.contains("press ctrl+d again") {
            return true
        }

        return false
    }
}
