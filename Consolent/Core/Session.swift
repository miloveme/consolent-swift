import Foundation
import SwiftTerm

/// 단일 Claude Code 세션.
/// PTY 프로세스 + 출력 버퍼 + 상태 + 응답 감지를 관리한다.
final class Session: ObservableObject, Identifiable, @unchecked Sendable {

    // MARK: - Types

    enum Status: String, Codable, Sendable {
        case initializing
        case ready
        case busy
        case waitingApproval = "waiting_approval"
        case error
        case terminated
    }

    struct Config {
        var workingDirectory: String
        var shell: String = "/bin/zsh"
        var cliType: CLIType = .claudeCode
        var cliArgs: [String] = []
        var autoApprove: Bool = false
        var idleTimeout: Int = 3600
        var env: [String: String]? = nil
    }

    struct MessageResponse: Codable {
        let messageId: String
        let response: ResponseBody
    }

    struct ResponseBody: Codable {
        let result: String
        let raw: String?
        let filesChanged: [String]
        let durationMs: Int
    }

    // MARK: - Properties

    let id: String
    let config: Config
    let adapter: CLIAdapter
    let createdAt: Date

    @Published private(set) var status: Status = .initializing
    @Published private(set) var pendingApproval: OutputParser.ApprovalRequest? = nil
    @Published private(set) var messageCount: Int = 0

    /// 전체 출력 버퍼 (ANSI 포함 원본)
    @Published private(set) var outputBuffer: Data = Data()

    /// 터미널 뷰에 표시할 출력 콜백
    var onTerminalOutput: ((Data) -> Void)?

    /// Headless 터미널 에뮬레이터.
    /// TerminalView 유무에 관계없이 항상 ANSI 해석된 화면 버퍼를 제공한다.
    private let headlessTerminal: Terminal
    private let headlessDelegate = HeadlessTerminalDelegate()

    let ptyProcess = PTYProcess()
    private let parser = OutputParser()
    private let maxBufferSize = 10 * 1024 * 1024  // 10MB

    // 메시지 응답 대기용
    private var responseContinuation: CheckedContinuation<MessageResponse, Error>?
    private var currentMessageId: String?
    private var currentResponseBuffer = Data()
    private var messageStartTime: Date?

    // MARK: - Init

    init(id: String? = nil, config: Config) {
        self.id = id ?? "s_\(UUID().uuidString.prefix(8).lowercased())"
        self.config = config
        self.adapter = config.cliType.createAdapter()
        self.createdAt = Date()
        self.headlessTerminal = Terminal(delegate: headlessDelegate, options: TerminalOptions(cols: 120, rows: 40))
        setupCallbacks()
    }

    // MARK: - Lifecycle

    /// 세션을 시작한다. CLI를 PTY에서 실행.
    func start() async throws {
        // CLI 바이너리 경로 찾기
        let binaryPath = adapter.findBinaryPath()

        // shell에서 CLI를 실행하는 명령 구성
        var shellArgs = ["-l", "-c"]
        let cliCommand = adapter.buildCommand(
            binaryPath: binaryPath,
            args: config.cliArgs,
            autoApprove: config.autoApprove
        )
        shellArgs.append(cliCommand)

        try ptyProcess.start(
            executable: config.shell,
            args: shellArgs,
            cwd: config.workingDirectory,
            env: config.env
        )

        // CLI 초기화 완료 대기 (프롬프트 출현)
        try await waitForReady(timeout: 30)
    }

    /// 메시지를 보내고 응답을 기다린다 (동기 방식).
    func sendMessage(text: String, timeout: TimeInterval = 300) async throws -> MessageResponse {
        guard status == .ready else {
            throw SessionError.notReady(currentStatus: status)
        }

        let messageId = "m_\(UUID().uuidString.prefix(8).lowercased())"

        await MainActor.run { status = .busy }
        currentMessageId = messageId
        currentResponseBuffer = Data()
        messageStartTime = Date()

        // 콘텐츠 체크 모드로 응답 완료 감지
        parser.completionMode = .contentCheck
        parser.idleTimeout = 1.0
        parser.startMonitoring()

        // PTY에 입력 (텍스트와 Enter를 분리하여 TUI가 제출을 인식하도록 함)
        try ptyProcess.write(text)
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        try ptyProcess.write("\r")
        await MainActor.run { messageCount += 1 }

        // 응답 완료 대기
        return try await withCheckedThrowingContinuation { continuation in
            self.responseContinuation = continuation

            // 타임아웃 설정
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.currentMessageId == messageId else { return }
                self.completeResponse(signal: .idleTimeout)
            }
        }
    }

    /// Raw 입력을 PTY에 주입한다.
    func injectInput(text: String) throws {
        try ptyProcess.write(text)
    }

    /// Raw 바이트를 PTY에 주입한다.
    func injectInput(data: Data) throws {
        try ptyProcess.write(data)
    }

    /// 승인 요청에 응답한다.
    func respondToApproval(id: String, approved: Bool) throws {
        guard let pending = pendingApproval, pending.id == id else {
            throw SessionError.noSuchApproval(id: id)
        }

        let response = approved ? "y\r" : "n\r"
        try ptyProcess.write(response)
        let hasActiveContinuation = responseContinuation != nil
        DispatchQueue.main.async { [self] in
            pendingApproval = nil
            status = hasActiveContinuation ? .busy : .ready
        }
    }

    /// 세션을 종료한다.
    func stop() {
        parser.stopMonitoring()

        // CLI에 종료 명령 시도
        try? ptyProcess.write(adapter.exitCommand + "\r")

        // 1초 후 프로세스 종료
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.ptyProcess.terminate()
        }

        DispatchQueue.main.async { [self] in
            status = .terminated
        }
    }

    // MARK: - Private

    private func setupCallbacks() {
        // 파서에 어댑터 연결
        parser.adapter = adapter

        // Screen buffer 기반 완료 감지용 클로저.
        // 마지막 비어있지 않은 줄을 찾아 그 주변 15줄을 읽는다.
        // Gemini CLI는 처리 표시(esc to cancel)가 하단에서 ~10줄 위에 있으므로
        // 충분한 범위를 읽어야 한다. Claude Code는 full-screen이라 영향 없음.
        parser.screenBufferChecker = { [weak self] in
            guard let self else { return "" }
            let terminal = self.headlessTerminal

            // 마지막 비어있지 않은 줄 찾기
            var lastNonEmptyRow = terminal.rows - 1
            for row in stride(from: terminal.rows - 1, through: 0, by: -1) {
                if let line = terminal.getLine(row: row),
                   !line.translateToString(trimRight: true).isEmpty {
                    lastNonEmptyRow = row
                    break
                }
            }

            let startRow = max(0, lastNonEmptyRow - 14)
            var lines: [String] = []
            for row in startRow...lastNonEmptyRow {
                if let line = terminal.getLine(row: row) {
                    lines.append(line.translateToString(trimRight: true))
                }
            }
            return lines.joined(separator: "\n")
        }

        // PTY 출력 처리
        ptyProcess.onOutput = { [weak self] data in
            guard let self else { return }
            self.handleOutput(data)
        }

        // 프로세스 상태 변화
        ptyProcess.onStateChange = { [weak self] state in
            guard let self else { return }
            if case .terminated = state {
                DispatchQueue.main.async {
                    self.status = .terminated
                }
                self.parser.stopMonitoring()
            }
        }

        // 응답 완료 감지
        parser.onResponseComplete = { [weak self] signal in
            guard let self else { return }
            self.completeResponse(signal: signal)
        }

        // 승인 프롬프트 감지
        parser.onApprovalDetected = { [weak self] approval in
            guard let self else { return }
            DispatchQueue.main.async {
                self.pendingApproval = approval
                self.status = .waitingApproval
            }

            // auto_approve 모드
            if self.config.autoApprove {
                try? self.respondToApproval(id: approval.id, approved: true)
            }
        }
    }

    private func handleOutput(_ data: Data) {
        // 출력 버퍼에 추가 (@Published — main thread)
        DispatchQueue.main.async { [self] in
            outputBuffer.append(data)
            if outputBuffer.count > maxBufferSize {
                let excess = outputBuffer.count - maxBufferSize
                outputBuffer.removeFirst(excess)
            }
        }

        // 응답 수집 중이면 현재 응답 버퍼에도 추가
        if responseContinuation != nil {
            currentResponseBuffer.append(data)
        }

        // Headless 터미널에 피드 (ANSI 해석)
        headlessTerminal.feed(byteArray: [UInt8](data))

        // 터미널 뷰에 전달
        onTerminalOutput?(data)

        // 파서에 전달 (텍스트 변환)
        if let text = String(data: data, encoding: .utf8) {
            parser.processOutput(text)
        }
    }

    private func completeResponse(signal: OutputParser.CompletionSignal) {
        guard let continuation = responseContinuation,
              let messageId = currentMessageId else { return }

        parser.stopMonitoring()
        responseContinuation = nil
        currentMessageId = nil

        let rawText = String(data: currentResponseBuffer, encoding: .utf8) ?? ""

        // Headless 터미널 버퍼에서 화면 텍스트 읽기 (항상 사용 가능)
        let screenText = readHeadlessBuffer()
        let cleanText = adapter.cleanResponse(screenText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 디버그: 빈 응답일 때 screen buffer 로그
        if cleanText.isEmpty {
            print("[Session] ⚠️ Empty cleanText. Signal: \(signal)")
            let debugLines = screenText.components(separatedBy: "\n")
                .enumerated()
                .filter { !$0.element.trimmingCharacters(in: .whitespaces).isEmpty }
                .map { "  [\($0.offset)] \($0.element)" }
                .joined(separator: "\n")
            print("[Session] screenText (non-empty lines):\n\(debugLines)")
        }

        let filesChanged = OutputParser.extractChangedFiles(from: rawText)

        let duration = Int((Date().timeIntervalSince(messageStartTime ?? Date())) * 1000)

        let response = MessageResponse(
            messageId: messageId,
            response: ResponseBody(
                result: cleanText,
                raw: AppConfig.shared.includeRawOutput ? rawText : nil,
                filesChanged: filesChanged,
                durationMs: duration
            )
        )

        currentResponseBuffer = Data()
        messageStartTime = nil
        DispatchQueue.main.async { [self] in
            status = .ready
        }

        continuation.resume(returning: response)
    }

    private func waitForReady(timeout: TimeInterval) async throws {
        // 프롬프트가 나타날 때까지 출력 감시
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resolved = false
            let originalCallback = parser.onResponseComplete

            parser.onResponseComplete = { [weak self] signal in
                guard let self, !resolved else { return }
                resolved = true
                self.parser.onResponseComplete = originalCallback
                self.parser.stopMonitoring()
                DispatchQueue.main.async {
                    self.status = .ready
                }
                continuation.resume()
            }

            parser.completionMode = .idleOnly
            parser.idleTimeout = 10.0  // 초기화 시 충분한 여유
            parser.startMonitoring()

            // 타임아웃
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard !resolved else { return }
                resolved = true
                self?.parser.stopMonitoring()
                // 타임아웃이어도 ready로 처리 (프롬프트 패턴이 안 맞았을 수 있음)
                self?.status = .ready
                continuation.resume()
            }
        }

        // 메시지 응답 대기용 설정으로 복원
        parser.completionMode = .contentCheck
        parser.idleTimeout = 1.0
    }

    /// Headless 터미널 버퍼에서 현재 화면 텍스트를 읽는다.
    func readHeadlessBuffer() -> String {
        var lines: [String] = []
        for row in 0..<headlessTerminal.rows {
            if let line = headlessTerminal.getLine(row: row) {
                lines.append(line.translateToString(trimRight: true))
            }
        }
        return lines.joined(separator: "\n")
    }

}

// MARK: - Errors

enum SessionError: LocalizedError {
    case notReady(currentStatus: Session.Status)
    case noSuchApproval(id: String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .notReady(let status): return "Session is not ready (status: \(status.rawValue))"
        case .noSuchApproval(let id): return "No pending approval with id: \(id)"
        case .timeout: return "Operation timed out"
        }
    }
}

// MARK: - Headless Terminal Delegate

/// Headless Terminal용 최소 delegate 구현.
/// 화면 렌더링 없이 ANSI 해석만 수행하므로 대부분의 콜백은 no-op이다.
final class HeadlessTerminalDelegate: TerminalDelegate {
    func send(source: Terminal, data: ArraySlice<UInt8>) {}
    func showCursor(source: Terminal) {}
    func hideCursor(source: Terminal) {}
    func setTerminalTitle(source: Terminal, title: String) {}
    func setTerminalIconTitle(source: Terminal, title: String) {}
    func sizeChanged(source: Terminal) {}
    func scrolled(source: Terminal, yDisp: Int) {}
    func linefeed(source: Terminal) {}
    func bufferActivated(source: Terminal) {}
    func bell(source: Terminal) {}
    func selectionChanged(source: Terminal) {}
    func isProcessTrusted(source: Terminal) -> Bool { false }
    func mouseModeChanged(source: Terminal) {}
    func cursorStyleChanged(source: Terminal, newStyle: CursorStyle) {}
    func hostCurrentDirectoryUpdated(source: Terminal) {}
    func hostCurrentDocumentUpdated(source: Terminal) {}
    func iTermContent(source: Terminal, content: ArraySlice<UInt8>) {}
    func clipboardCopy(source: Terminal, content: Data) {}
    func notify(source: Terminal, title: String, body: String) {}
    func colorChanged(source: Terminal, idx: Int?) {}
    func setForegroundColor(source: Terminal, color: SwiftTerm.Color) {}
    func setBackgroundColor(source: Terminal, color: SwiftTerm.Color) {}
    func setCursorColor(source: Terminal, color: SwiftTerm.Color?) {}
    func getColors(source: Terminal) -> (foreground: SwiftTerm.Color, background: SwiftTerm.Color) {
        (SwiftTerm.Color(red: 59110, green: 59110, blue: 59110), SwiftTerm.Color(red: 6682, green: 6682, blue: 7967))
    }
    func synchronizedOutputChanged(source: Terminal, active: Bool) {}
    func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { nil }
    func cellSizeInPixels(source: Terminal) -> (width: Int, height: Int)? { nil }
    func progressReport(source: Terminal, report: Terminal.ProgressReport) {}
    func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {}
    func createImage(source: Terminal, data: Data, width: ImageSizeRequest, height: ImageSizeRequest, preserveAspectRatio: Bool) {}
}
