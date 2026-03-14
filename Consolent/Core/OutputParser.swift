import Foundation

/// CLI 도구의 PTY 출력을 파싱한다.
/// - ANSI 이스케이프 코드 제거
/// - 응답 완료(프롬프트 복귀) 감지
/// - 승인 프롬프트(Y/n) 감지
final class OutputParser {

    // MARK: - Types

    struct ApprovalRequest: Codable, Sendable {
        let id: String
        let prompt: String
        let detectedAt: Date
    }

    enum CompletionSignal {
        case responseComplete        // 응답 완료 감지 (idle + 처리 표시 없음)
        case idleTimeout             // 안전망: 최대 대기 시간 초과
    }

    /// 완료 감지 모드
    enum CompletionMode {
        case idleOnly       // waitForReady: 단순 idle 타임아웃
        case contentCheck   // 메시지 응답: idle + "esc to interrupt" 소멸 확인
    }

    // MARK: - Properties

    /// Claude Code 프롬프트 패턴 (응답 완료 판단용)
    /// Claude Code는 응답 완료 후 입력 대기 시 `>` 프롬프트를 표시한다.
    /// 주의: 입력 에코 중에 나타나는 패턴(status bar 등)은 포함하면 안 됨.
    var promptPatterns: [NSRegularExpression] = {
        let patterns = [
            // Claude Code의 `›` (U+203A) 입력 프롬프트 (ANSI 제거 후)
            "^\\s*›\\s*$",
            "\\n\\s*›\\s*$",
            // ASCII `>` 프롬프트 (fallback)
            "^\\s*>\\s*$",
            "\\n\\s*>\\s*$",
            // `❯` (U+276F) 프롬프트 (일부 터미널 환경)
            "^\\s*❯\\s*$",
            "\\n\\s*❯\\s*$",
            // $ 프롬프트
            "^\\$\\s*$",
            "\\n\\$\\s*$",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.anchorsMatchLines]) }
    }()

    /// 승인 프롬프트 패턴
    private let approvalPatterns: [NSRegularExpression] = {
        let patterns = [
            "\\(y/n\\)\\s*$",
            "\\(Y/n\\)\\s*$",
            "\\[y/N\\]\\s*$",
            "\\[Y/n\\]\\s*$",
            "Do you want to proceed\\?",
            "Allow .+\\?\\s*\\(y\\)",
            "Press Enter to continue",
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }
    }()

    /// 완료 감지 모드. 메시지 응답 시 .contentCheck, 초기화 시 .idleOnly.
    var completionMode: CompletionMode = .idleOnly

    /// Idle 체크 간격 (초). 이 시간 동안 출력이 없으면 완료 조건을 확인한다.
    /// 처리 중에는 TUI 스피너가 계속 출력을 생성하므로, 출력 멈춤 = 처리 완료.
    var idleTimeout: TimeInterval = 2.0

    /// 절대 안전망 타임아웃 (초). 이 시간이 지나면 무조건 완료 처리.
    /// message timeout (기본 300초)보다 길어야 함.
    private let maxMonitoringDuration: TimeInterval = 600.0

    /// CLI 어댑터 참조 (완료 감지에 사용)
    var adapter: CLIAdapter?

    /// Headless terminal screen buffer 읽기 (ANSI 해석 완료된 텍스트)
    var screenBufferChecker: (() -> String)?
    private var monitoringStartTime: Date?

    private var lastOutputTime: Date = Date()
    private var idleTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.consolent.parser.timer")

    /// 최근 stripped 텍스트 누적 버퍼 (청크 경계를 넘는 프롬프트 감지용)
    private var recentStrippedText = ""
    private let recentTextMaxLength = 500

    var onResponseComplete: ((CompletionSignal) -> Void)?
    var onApprovalDetected: ((ApprovalRequest) -> Void)?

    // MARK: - ANSI Stripping

    /// ANSI 이스케이프 코드를 제거한 순수 텍스트를 반환한다.
    ///
    /// Claude Code는 TUI를 사용하여 커서 위치 이동으로 화면을 그린다.
    /// 단순히 모든 이스케이프를 삭제하면 줄 구조가 사라져서 프롬프트 감지가 실패한다.
    /// 따라서 3단계로 처리한다:
    /// 1. 수직 커서 이동 → `\n` (줄 구조 보존)
    /// 2. 수평 커서 이동 → ` ` (단어 간격 보존)
    /// 3. 나머지 ANSI 코드 제거
    static func stripANSI(_ text: String) -> String {
        var result = text

        // Phase 1: 수직 커서 이동 / 화면 제어 → 개행 (줄 구조 보존)
        // CUP(\x1B[n;mH), CUU(\x1B[nA), CUD(\x1B[nB),
        // ED(\x1B[2J clear screen), EL(\x1B[2K clear line)
        let verticalPattern = [
            "\\x1B\\[[0-9]*;?[0-9]*H",     // CUP: cursor absolute position
            "\\x1B\\[[0-9]*A",               // CUU: cursor up
            "\\x1B\\[[0-9]*B",               // CUD: cursor down
            "\\x1B\\[2J",                    // ED:  clear entire screen
            "\\x1B\\[2K",                    // EL:  clear entire line
        ].joined(separator: "|")

        if let regex = try? NSRegularExpression(pattern: verticalPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "\n")
        }

        // Phase 2: 수평 커서 이동 → 공백 (단어 간격 보존)
        // Claude Code는 \x1B[1C 를 단어 사이 공백으로 사용한다.
        let horizontalPattern = [
            "\\x1B\\[[0-9]*C",              // CUF: cursor forward
            "\\x1B\\[[0-9]*G",              // CHA: cursor horizontal absolute
        ].joined(separator: "|")

        if let regex = try? NSRegularExpression(pattern: horizontalPattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: " ")
        }

        // Phase 3: 나머지 ANSI 이스케이프 코드 제거
        let removePattern = [
            "\\x1B\\[[?!>]?[0-9;]*[ -/]*[A-Za-z@-~]",  // CSI (remaining SGR, scroll, etc.)
            "\\x1B\\][^\\x07\\x1B]*(?:\\x07|\\x1B\\\\)", // OSC sequences
            "\\x1B\\([A-Za-z]",                           // Character set designation
            "\\x1B[=>]",                                   // Keypad mode
            "\\r",                                         // Carriage return
        ].joined(separator: "|")

        if let regex = try? NSRegularExpression(pattern: removePattern, options: []) {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "")
        }

        // Phase 4: 정리 — 연속 빈 줄, 앞뒤 공백
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Output Processing

    /// 새 출력 데이터를 처리한다.
    /// 승인 감지를 수행하고 idle 타이머를 리셋한다.
    /// 응답 완료는 idle 타이머 + 콘텐츠 확인으로 감지한다.
    /// (› 프롬프트는 처리 중에도 항상 표시되므로 완료 신호로 사용할 수 없음)
    func processOutput(_ text: String) {
        lastOutputTime = Date()
        resetIdleTimer()

        let stripped = OutputParser.stripANSI(text)

        // 최근 텍스트 누적 (콘텐츠 확인용)
        recentStrippedText += stripped
        if recentStrippedText.count > recentTextMaxLength {
            recentStrippedText = String(recentStrippedText.suffix(recentTextMaxLength))
        }

        // 승인 프롬프트 감지 (현재 청크에서)
        if let approval = detectApproval(in: stripped) {
            onApprovalDetected?(approval)
            return
        }

        // 빠른 완료 감지: screen buffer에서 readySignal만 확인
        // 주의: isResponseComplete()는 사용하면 안 됨.
        // 메시지 전송 직후 처리 시작 전에 두 신호 모두 없는 순간이 있어
        // !hasProcessing이 true가 되어 즉시 완료로 오인됨.
        // readySignal 존재 여부만 확인해야 정확.
        if completionMode == .contentCheck, let checker = screenBufferChecker {
            let screen = checker()
            let readySignal = adapter?.readySignal ?? "? for shortcuts"
            if screen.contains(readySignal) {
                cancelIdleTimer()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                    guard let self else { return }
                    self.onResponseComplete?(.responseComplete)
                }
                return
            }
        }

        // 나머지 응답 완료 감지는 idle 타이머 핸들러에서 수행.
        // 처리 중에는 TUI 스피너가 계속 출력을 생성하므로 타이머가 리셋됨.
        // 출력이 멈추면 타이머가 만료되고, 그때 "esc to interrupt" 부재를 확인.
    }

    /// idle 타이머를 시작한다. 메시지 전송 시 호출.
    func startMonitoring() {
        lastOutputTime = Date()
        monitoringStartTime = Date()
        recentStrippedText = ""
        resetIdleTimer()
    }

    /// 모니터링을 중지한다.
    func stopMonitoring() {
        cancelIdleTimer()
        recentStrippedText = ""
    }

    // MARK: - Detection

    /// 텍스트에서 Claude Code 프롬프트를 감지한다.
    func detectPrompt(in text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in promptPatterns {
            if pattern.firstMatch(in: text, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    /// 텍스트에서 승인 프롬프트를 감지한다.
    func detectApproval(in text: String) -> ApprovalRequest? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in approvalPatterns {
            if pattern.firstMatch(in: text, options: [], range: range) != nil {
                // 마지막 줄을 프롬프트 텍스트로 사용
                let lastLine = text.components(separatedBy: "\n")
                    .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? text

                return ApprovalRequest(
                    id: "a_\(UUID().uuidString.prefix(8).lowercased())",
                    prompt: lastLine.trimmingCharacters(in: .whitespacesAndNewlines),
                    detectedAt: Date()
                )
            }
        }
        return nil
    }

    // MARK: - Response Text Extraction

    /// Raw PTY 출력에서 Claude Code의 최종 응답 텍스트만 추출한다.
    ///
    /// Claude Code TUI는 full-screen redraw를 반복하므로,
    /// 마지막 전체 화면 다시 그리기의 내용만 추출하고 TUI chrome을 제거한다.
    static func extractResponseText(from rawText: String) -> String {
        // Step 1: 마지막 전체 화면 다시 그리기 블록을 찾는다
        let block = lastFullScreenRedraw(in: rawText) ?? rawText

        // Step 2: ANSI 코드를 제거한다
        let stripped = stripANSI(block)

        // Step 3: TUI chrome을 제거한다
        let cleaned = cleanTUIContent(stripped)

        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Raw 텍스트에서 마지막 전체 화면 redraw 블록을 찾는다.
    ///
    /// Claude Code TUI는 화면을 다시 그릴 때 큰 cursor-up 시퀀스(\x1B[NA, N >= 10)를
    /// 보내고 위에서부터 다시 그린다. 마지막 이런 시퀀스 이후의 텍스트가 최종 화면 상태이다.
    static func lastFullScreenRedraw(in rawText: String) -> String? {
        // \x1B[NA 패턴에서 N >= 10인 것을 찾는다 (전체 화면 redraw)
        guard let regex = try? NSRegularExpression(
            pattern: "\\x1B\\[(\\d+)A",
            options: []
        ) else { return nil }

        let nsRange = NSRange(rawText.startIndex..., in: rawText)
        let matches = regex.matches(in: rawText, options: [], range: nsRange)

        // N >= 10인 마지막 매치를 찾는다
        var lastMatchEnd: String.Index?
        for match in matches.reversed() {
            if let numRange = Range(match.range(at: 1), in: rawText),
               let n = Int(rawText[numRange]), n >= 10 {
                // 이 매치의 시작 위치부터 끝까지가 최종 redraw 블록
                if let fullRange = Range(match.range, in: rawText) {
                    lastMatchEnd = fullRange.lowerBound
                    break
                }
            }
        }

        guard let start = lastMatchEnd else { return nil }
        return String(rawText[start...])
    }

    /// 터미널 화면 버퍼 텍스트에서 Claude Code TUI chrome을 제거하고
    /// 응답 본문만 추출한다.
    ///
    /// 처리 순서:
    /// 1. Null 문자 제거 (SwiftTerm 빈 셀)
    /// 2. 환영 화면 박스 제거 (│...│ 패턴)
    /// 3. 사용자 입력 줄 이후부터 추출
    /// 4. TUI chrome 제거 (구분선, 프롬프트, 푸터)
    static func cleanTUIContent(_ text: String) -> String {
        // Step 1: Null 문자 → 공백 대체 (SwiftTerm 빈 셀이 공백 역할)
        var cleaned = text.replacingOccurrences(of: "\u{0000}", with: " ")

        // 역방향 삭제 제어 문자도 제거
        cleaned = cleaned.replacingOccurrences(of: "\u{007F}", with: "")

        let lines = cleaned.components(separatedBy: "\n")

        // Step 2: 환영 화면 박스 & TUI chrome 제거, 응답 본문 추출
        // Claude의 응답은 ⏺ 마커로 시작한다.
        // 사용자 입력은 ❯ 또는 › 로 시작한다.
        var responseLines: [String] = []
        var foundResponseStart = false

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 빈 줄 처리
            if trimmed.isEmpty {
                if foundResponseStart {
                    responseLines.append("")
                }
                continue
            }

            // 박스 테두리 줄 — 응답 시작 전에만 필터링 (환영 화면)
            if !foundResponseStart && isBoxBorderLine(trimmed) {
                continue
            }

            // 구분선 (───)
            if trimmed.hasPrefix("───") || trimmed.hasPrefix("━━━") || trimmed.allSatisfy({ $0 == "─" || $0 == "━" }) {
                continue
            }

            // 프롬프트만 있는 줄 (입력 없는 빈 프롬프트)
            if trimmed == "›" || trimmed == "❯" || trimmed == ">" || trimmed == "$" {
                continue
            }

            // 사용자 입력 줄 (❯ + 메시지) — 매번 리셋하여 마지막 턴만 남긴다
            if trimmed.hasPrefix("❯ ") || trimmed.hasPrefix("› ") {
                responseLines = []
                foundResponseStart = true
                continue
            }

            // ⏺ 마커로 시작하면 응답 시작 (사용자 입력 줄이 없는 경우 대비)
            if !foundResponseStart && trimmed.hasPrefix("⏺") {
                foundResponseStart = true
            }

            // 푸터 / 상태 텍스트
            if matchesTUIChrome(trimmed) {
                continue
            }

            // 스피너 문자만 있는 줄
            if isSpinnerOnlyLine(trimmed) {
                continue
            }

            if foundResponseStart {
                // TUI 도구 사용 표시 제거: "⏺ Read N file(s) (...)" 등
                if trimmed.hasPrefix("⏺") {
                    // "⏺ Read/Wrote/Ran/Created ... (ctrl+o ...)" 패턴은 TUI chrome
                    if trimmed.range(of: "⏺\\s+(Read|Wrote|Ran|Created|Updated|Deleted|Searched|Listed)\\s+.*\\(ctrl\\+", options: .regularExpression) != nil {
                        continue
                    }
                    // 그 외 ⏺는 응답 텍스트 — 접두어 제거
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
                if !lastWasEmpty {
                    result.append("")
                }
                lastWasEmpty = true
            } else {
                // 각 줄의 trailing 공백 제거
                result.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
                lastWasEmpty = false
            }
        }

        return result.joined(separator: "\n")
    }

    /// 박스 테두리 줄인지 확인 (│ 로 시작하고 끝나는 줄, ╭, ╮, ╰, ╯)
    private static func isBoxBorderLine(_ text: String) -> Bool {
        let boxChars: Set<Character> = ["│", "║", "┃", "╭", "╮", "╰", "╯", "┌", "┐", "└", "┘", "├", "┤", "┬", "┴", "┼"]

        // 첫 문자가 박스 문자이면 박스 라인
        if let first = text.first, boxChars.contains(first) {
            return true
        }
        // 마지막 문자가 박스 문자이면 박스 라인
        if let last = text.last, boxChars.contains(last) {
            return true
        }
        return false
    }

    /// 스피너 문자만 있는 줄인지 확인
    private static func isSpinnerOnlyLine(_ text: String) -> Bool {
        let spinnerChars: Set<Character> = [
            "✳", "✶", "✻", "✽", "✢", "·", "◉", "○", "◍", "◎", "●",
            "◐", "◑", "◒", "◓", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
        ]
        let nonSpaceChars = text.filter { !$0.isWhitespace }
        return !nonSpaceChars.isEmpty && nonSpaceChars.allSatisfy({ spinnerChars.contains($0) })
    }

    /// TUI chrome 텍스트 패턴 매칭
    private static func matchesTUIChrome(_ text: String) -> Bool {
        // 빠른 문자열 매칭 (regex 없이)
        let lowered = text.lowercased()
        let quickPatterns = [
            "esc to interrupt",
            "? for shortcuts",
            "api error",
        ]
        for pattern in quickPatterns {
            if lowered.contains(pattern) { return true }
        }

        // "Razzle-dazzling…" 등 스피너 상태 텍스트
        let statusPatterns = [
            "Streaming…", "Flowing…", "Thinking…", "Processing…",
            "Reading…", "Writing…", "Searching…", "Analyzing…",
            "Razzle-dazzling…", "Razzle-dazzling...",
        ]
        for pattern in statusPatterns {
            if text.contains(pattern) { return true }
        }

        // Regex 패턴 (토큰 카운트, 툴 사용 등)
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

    /// 출력에서 변경된 파일 목록을 추출한다 (best-effort).
    static func extractChangedFiles(from text: String) -> [String] {
        var files: Set<String> = []
        let stripped = stripANSI(text)

        // "Edit <file>" 패턴
        let editPattern = try? NSRegularExpression(pattern: "(?:Edit|Write|Create)(?:ing)?\\s+([\\w/.\\-]+\\.\\w+)", options: [])
        if let editPattern {
            let range = NSRange(stripped.startIndex..., in: stripped)
            let matches = editPattern.matches(in: stripped, options: [], range: range)
            for match in matches {
                if let fileRange = Range(match.range(at: 1), in: stripped) {
                    files.insert(String(stripped[fileRange]))
                }
            }
        }

        // "--- a/<file>" or "+++ b/<file>" (diff 패턴)
        let diffPattern = try? NSRegularExpression(pattern: "^[+-]{3} [ab]/(.+)$", options: [.anchorsMatchLines])
        if let diffPattern {
            let range = NSRange(stripped.startIndex..., in: stripped)
            let matches = diffPattern.matches(in: stripped, options: [], range: range)
            for match in matches {
                if let fileRange = Range(match.range(at: 1), in: stripped) {
                    files.insert(String(stripped[fileRange]))
                }
            }
        }

        return Array(files).sorted()
    }

    // MARK: - Private

    private func resetIdleTimer() {
        cancelIdleTimer()

        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + idleTimeout)
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            switch self.completionMode {
            case .idleOnly:
                // 초기화 모드: 단순 idle 타임아웃 → 완료
                DispatchQueue.main.async {
                    self.onResponseComplete?(.idleTimeout)
                }

            case .contentCheck:
                if self.isProcessingFinished() {
                    // 처리 완료: 출력 멈춤 + "esc to interrupt" 없음
                    DispatchQueue.main.async {
                        self.onResponseComplete?(.responseComplete)
                    }
                } else if let start = self.monitoringStartTime,
                          Date().timeIntervalSince(start) > self.maxMonitoringDuration {
                    // 안전망: 120초 초과 → 강제 완료
                    DispatchQueue.main.async {
                        self.onResponseComplete?(.idleTimeout)
                    }
                } else {
                    // 아직 처리 중 — 다시 체크 대기
                    self.resetIdleTimer()
                }
            }
        }
        timer.resume()
        self.idleTimer = timer
    }

    /// 최근 출력에서 처리 중 표시가 사라졌는지 확인한다.
    /// CLI TUI는 처리 중 고유한 표시를 하고, 완료 시 readySignal로 교체한다.
    private func isProcessingFinished() -> Bool {
        // Screen buffer 기반 확인 (더 신뢰성 높음)
        if let checker = screenBufferChecker {
            let screen = checker()
            if let adapter = adapter {
                return adapter.isResponseComplete(screenBuffer: screen)
            }
            // fallback: Claude Code 기본 패턴
            let hasReadyIndicator = screen.contains("? for shortcuts")
            let hasProcessingIndicator = screen.range(
                of: "esc\\s+to\\s+interrupt",
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return hasReadyIndicator || !hasProcessingIndicator
        }

        // Fallback: stripANSI 기반
        let tail = String(recentStrippedText.suffix(300))
        if let adapter = adapter {
            let hasReady = tail.contains(adapter.readySignal)
            if let processing = adapter.processingSignal {
                let hasProcessing = tail.range(
                    of: processing,
                    options: [.regularExpression, .caseInsensitive]
                ) != nil
                return hasReady || !hasProcessing
            }
            return hasReady
        }

        // fallback: Claude Code 기본 패턴
        let hasProcessingIndicator = tail.range(
            of: "esc\\s+to\\s+interrupt",
            options: [.regularExpression, .caseInsensitive]
        ) != nil

        let hasReadyIndicator = tail.range(
            of: "\\?\\s+for\\s+shortcuts",
            options: [.regularExpression, .caseInsensitive]
        ) != nil
        return hasReadyIndicator || !hasProcessingIndicator
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }
}
