import Foundation

/// CLI 도구의 PTY 출력을 파싱한다.
/// - ANSI 이스케이프 코드 제거
/// - 응답 완료(프롬프트 복귀) 감지
/// - 승인 프롬프트(Y/n) 감지
///
/// CLI별 고유 패턴(프롬프트, 승인, 응답 파싱)은 CLIAdapter에서 제공받는다.
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
        case contentCheck   // 메시지 응답: idle + processingSignal 소멸 확인
    }

    // MARK: - Properties

    /// 완료 감지 모드. 메시지 응답 시 .contentCheck, 초기화 시 .idleOnly.
    var completionMode: CompletionMode = .idleOnly

    /// Idle 체크 간격 (초). 이 시간 동안 출력이 없으면 완료 조건을 확인한다.
    /// 처리 중에는 TUI 스피너가 계속 출력을 생성하므로, 출력 멈춤 = 처리 완료.
    var idleTimeout: TimeInterval = 2.0

    /// 절대 안전망 타임아웃 (초). 이 시간이 지나면 무조건 완료 처리.
    /// message timeout (기본 300초)보다 길어야 함.
    private let maxMonitoringDuration: TimeInterval = 600.0

    /// CLI 어댑터 참조 (완료 감지, 승인 패턴에 사용)
    var adapter: CLIAdapter?

    /// Headless terminal screen buffer 읽기 (ANSI 해석 완료된 텍스트)
    var screenBufferChecker: (() -> String)?
    private var monitoringStartTime: Date?

    private var isMonitoring = false
    private var lastOutputTime: Date = Date()
    private var idleTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.consolent.parser.timer")

    /// 최근 stripped 텍스트 누적 버퍼 (청크 경계를 넘는 프롬프트 감지용)
    private var recentStrippedText = ""
    private let recentTextMaxLength = 500

    /// 컴파일된 승인 패턴 (adapter 변경 시 재생성)
    private var compiledApprovalPatterns: [NSRegularExpression] = []

    var onResponseComplete: ((CompletionSignal) -> Void)?
    var onApprovalDetected: ((ApprovalRequest) -> Void)?

    // MARK: - ANSI Stripping

    /// ANSI 이스케이프 코드를 제거한 순수 텍스트를 반환한다.
    ///
    /// CLI TUI는 커서 위치 이동으로 화면을 그린다.
    /// 단순히 모든 이스케이프를 삭제하면 줄 구조가 사라져서 프롬프트 감지가 실패한다.
    /// 따라서 3단계로 처리한다:
    /// 1. 수직 커서 이동 → `\n` (줄 구조 보존)
    /// 2. 수평 커서 이동 → ` ` (단어 간격 보존)
    /// 3. 나머지 ANSI 코드 제거
    static func stripANSI(_ text: String) -> String {
        var result = text

        // Phase 1: 수직 커서 이동 / 화면 제어 → 개행 (줄 구조 보존)
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
    func processOutput(_ text: String) {
        lastOutputTime = Date()
        guard isMonitoring else { return }
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

        // 응답 완료 감지는 idle 타이머 핸들러에서 수행.
        // 처리 중에는 TUI 스피너가 계속 출력을 생성하므로 타이머가 리셋됨.
        // 출력이 멈추면 타이머가 만료되고, 그때 adapter.isResponseComplete()를 확인.
    }

    /// idle 타이머를 시작한다. 메시지 전송 시 호출.
    func startMonitoring() {
        isMonitoring = true
        lastOutputTime = Date()
        monitoringStartTime = Date()
        recentStrippedText = ""
        rebuildApprovalPatterns()
        resetIdleTimer()
    }

    /// 모니터링을 중지한다.
    func stopMonitoring() {
        isMonitoring = false
        cancelIdleTimer()
        recentStrippedText = ""
    }

    // MARK: - Detection

    /// 텍스트에서 승인 프롬프트를 감지한다.
    /// 패턴은 adapter.approvalPatterns에서 제공받는다.
    func detectApproval(in text: String) -> ApprovalRequest? {
        let range = NSRange(text.startIndex..., in: text)
        for pattern in compiledApprovalPatterns {
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

    // MARK: - Utilities

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

    /// adapter의 승인 패턴을 컴파일한다.
    private func rebuildApprovalPatterns() {
        guard let adapter = adapter else {
            compiledApprovalPatterns = []
            return
        }
        compiledApprovalPatterns = adapter.approvalPatterns.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
    }

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
                    // 처리 완료: 출력 멈춤 + processingSignal 없음
                    DispatchQueue.main.async {
                        self.onResponseComplete?(.responseComplete)
                    }
                } else if let start = self.monitoringStartTime,
                          Date().timeIntervalSince(start) > self.maxMonitoringDuration {
                    // 안전망: 최대 대기 시간 초과 → 강제 완료
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
    /// adapter의 readySignal/processingSignal을 사용한다.
    private func isProcessingFinished() -> Bool {
        // Screen buffer 기반 확인 (더 신뢰성 높음)
        if let checker = screenBufferChecker, let adapter = adapter {
            let screen = checker()
            return adapter.isResponseComplete(screenBuffer: screen)
        }

        // Fallback: stripANSI 기반
        if let adapter = adapter {
            let tail = String(recentStrippedText.suffix(300))
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

        // adapter가 없으면 idle timeout에 의존
        return true
    }

    private func cancelIdleTimer() {
        idleTimer?.cancel()
        idleTimer = nil
    }
}
