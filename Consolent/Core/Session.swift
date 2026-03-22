import Foundation
import SwiftTerm
import Combine

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
        /// 세션 이름. OpenAI 호환 API의 model 필드로 사용된다.
        /// nil이면 cliType.rawValue가 기본값 (예: "claude-code", "gemini", "codex").
        var name: String? = nil
        var workingDirectory: String
        var shell: String = "/bin/zsh"
        var cliType: CLIType = .claudeCode
        var cliArgs: [String] = []
        var autoApprove: Bool = false
        var idleTimeout: Int = 3600
        var env: [String: String]? = nil
        /// 채널 서버 모드 (Claude Code 전용). ON이면 MCP 채널 서버로 직접 API 제공.
        var channelEnabled: Bool = false
        /// 채널 서버 HTTP 포트 (기본 8787).
        var channelPort: Int = 8787
        /// MCP 서버 이름. ~/.claude.json의 mcpServers 키와 일치해야 함.
        var channelServerName: String = "openai-compat"
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

    /// 스트리밍 이벤트 타입
    enum StreamEvent: Sendable {
        case delta(String)           // 새 텍스트 청크
        case done(MessageResponse)   // 완료 + 메타데이터
        case error(String)           // 에러
    }

    // MARK: - Properties

    let id: String
    let config: Config
    let adapter: CLIAdapter
    let createdAt: Date

    /// 세션 이름. OpenAI 호환 API의 model 필드로 매칭된다.
    /// 기본값은 cliType.rawValue (예: "claude-code").
    @Published var name: String

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

    /// 세션별 Cloudflare Quick Tunnel 관리자
    let cloudflare = CloudflareManager()
    private var cancellables = Set<AnyCancellable>()

    /// 현재 활성 터널 URL (cloudflared 연결 완료 후 설정됨)
    var tunnelURL: String? { cloudflare.tunnelURL }

    /// 채널 서버 모드 활성 여부 (Claude Code + channelEnabled)
    var isChannelMode: Bool { config.channelEnabled && config.cliType == .claudeCode }

    /// 채널 서버 URL (채널 모드 활성 시)
    var channelServerURL: String? {
        isChannelMode ? "http://localhost:\(config.channelPort)" : nil
    }

    // 메시지 응답 대기용
    private var responseContinuation: CheckedContinuation<MessageResponse, Error>?
    private var currentMessageId: String?
    private var currentResponseBuffer = Data()
    private var messageStartTime: Date?

    // 스트리밍 전용 상태
    private var streamContinuation: AsyncStream<StreamEvent>.Continuation?
    private var streamSentLength: Int = 0
    private var streamPollTimer: DispatchSourceTimer?
    /// 메시지 전송 시점의 cleanResponse 결과 (이전 턴의 응답).
    /// 스트리밍 폴링에서 이전 응답이 그대로 반환되는 것을 감지하여 스킵하는 데 사용.
    private var streamBaselineText: String?

    // MARK: - Init

    init(id: String? = nil, config: Config) {
        self.id = id ?? "s_\(UUID().uuidString.prefix(8).lowercased())"
        self.config = config
        self.adapter = config.cliType.createAdapter()
        self.name = config.name ?? config.cliType.rawValue
        self.createdAt = Date()
        // scrollback 버퍼를 충분히 확보하여 긴 응답이 잘리지 않도록 한다.
        // 기본 500행 visible + 10000행 scrollback = 최대 10500행 보존.
        // readHeadlessBuffer()에서 getScrollInvariantLine()으로 전체를 읽는다.
        self.headlessTerminal = Terminal(delegate: headlessDelegate, options: TerminalOptions(cols: 120, rows: AppConfig.shared.headlessTerminalRows, scrollback: 10000))
        setupCallbacks()

        // cloudflare 상태 변화를 Session의 objectWillChange로 전달 (뷰 갱신용).
        // async로 지연하여 SwiftUI 뷰 업데이트 사이클과 충돌 방지.
        cloudflare.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.objectWillChange.send() }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// 세션을 시작한다. CLI를 PTY에서 실행.
    func start() async throws {
        // CLI 바이너리 경로 찾기
        let binaryPath = adapter.findBinaryPath()

        // shell에서 CLI를 실행하는 명령 구성
        // -li: login + interactive. interactive 플래그가 있어야 .zshrc가 소스되어
        // nvm, Homebrew 등 사용자 PATH 설정이 적용된다.
        var shellArgs = ["-li", "-c"]

        // 채널 모드: CLI 인자에 채널 플래그 추가
        var effectiveArgs = config.cliArgs
        if isChannelMode {
            effectiveArgs.insert(contentsOf: [
                "--dangerously-load-development-channels",
                "server:\(config.channelServerName)"
            ], at: 0)
        }

        let cliCommand = adapter.buildCommand(
            binaryPath: binaryPath,
            args: effectiveArgs,
            autoApprove: config.autoApprove
        )
        shellArgs.append(cliCommand)

        // 채널 모드: 환경 변수 주입 (채널 서버 포트)
        var effectiveEnv = config.env ?? [:]
        if isChannelMode {
            effectiveEnv["OPENAI_COMPAT_PORT"] = String(config.channelPort)
        }

        // PTY는 기본 크기(120x40)로 시작.
        // headlessTerminal(500행)은 별도 크기로 동일 데이터를 수신하여 긴 응답 마커를 보존.
        // PTY를 500행으로 하면 커서가 row 499에 → TerminalView에서 welcome 안 보임.
        // sizeChanged가 실제 표시 크기로 resize 해줌.
        try ptyProcess.start(
            executable: config.shell,
            args: shellArgs,
            cwd: config.workingDirectory,
            env: effectiveEnv.isEmpty ? nil : effectiveEnv
        )

        // 채널 모드: 개발 채널 선택 화면 자동 통과
        // Ink TUI 렌더링 특성상 텍스트 패턴 매칭이 불가하므로,
        // 화면 출력이 2초간 안정되면 선택 화면으로 판단하고 Enter 전송
        if isChannelMode {
            var lastBuffer = ""
            var stableCount = 0
            for _ in 0..<60 {  // 최대 30초
                try await Task.sleep(nanoseconds: 500_000_000)  // 0.5초
                let buffer = readHeadlessBuffer()
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty && trimmed == lastBuffer {
                    stableCount += 1
                    if stableCount >= 4 {  // 2초간 안정
                        try? ptyProcess.write("\r")
                        break
                    }
                } else {
                    stableCount = 0
                }
                lastBuffer = trimmed
            }
        }

        // CLI 초기화 완료 대기 (프롬프트 출현)
        try await waitForReady(timeout: 30)

        // 디버그 로깅: 세션 시작
        DebugLogger.shared.startSession(sessionId: id,
                                         cliType: config.cliType.rawValue,
                                         name: name)
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

        await MainActor.run { messageCount += 1 }

        // 응답 완료 대기 — continuation을 먼저 설정하여 race condition 방지
        return try await withCheckedThrowingContinuation { continuation in
            self.responseContinuation = continuation

            parser.completionMode = .contentCheck
            parser.idleTimeout = 1.0
            parser.startMonitoring()

            // 디버그 로깅: 메시지 전송
            DebugLogger.shared.logMessageSent(sessionId: id, messageId: messageId,
                                               text: text, streaming: false)

            do {
                try ptyProcess.write(text)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                    try? self.ptyProcess.write("\r")
                }
            } catch {
                self.responseContinuation = nil
                continuation.resume(throwing: error)
                return
            }

            // 타임아웃 설정
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                guard let self, self.currentMessageId == messageId else { return }
                self.completeResponse(signal: .idleTimeout)
            }
        }
    }

    /// 메시지를 보내고 응답을 실시간 스트리밍한다.
    /// PTY 출력이 올 때마다 화면을 스냅샷 → cleanResponse() → diff → delta 전송.
    func sendMessageStreaming(text: String, timeout: TimeInterval = 300) -> AsyncStream<StreamEvent> {
        let messageId = "m_\(UUID().uuidString.prefix(8).lowercased())"

        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()

        // status 확인
        guard status == .ready else {
            continuation.yield(.error("Session is not ready (status: \(status.rawValue))"))
            continuation.finish()
            return stream
        }

        DispatchQueue.main.async { [self] in
            status = .busy
            messageCount += 1
        }

        currentMessageId = messageId
        currentResponseBuffer = Data()
        messageStartTime = Date()
        streamContinuation = continuation
        streamSentLength = 0

        // 메시지 전송 전 현재 화면의 cleanResponse 결과를 baseline으로 캡처.
        // 이전 턴의 응답이 스트리밍 도중 다시 반환되는 것을 방지한다.
        // (Codex 등에서 backup/restore 로직으로 이전 응답이 복원될 수 있음)
        let currentScreen = readHeadlessBuffer()
        streamBaselineText = adapter.cleanResponse(currentScreen)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 디버그 로깅: 스트리밍 메시지 전송 + baseline
        DebugLogger.shared.logMessageSent(sessionId: id, messageId: messageId,
                                           text: text, streaming: true)
        DebugLogger.shared.logStreamingBaseline(sessionId: id,
                                                 baseline: streamBaselineText ?? "")

        // 파서 모니터링 시작
        parser.completionMode = .contentCheck
        parser.idleTimeout = 1.0
        parser.startMonitoring()

        // PTY에 텍스트 전송
        do {
            try ptyProcess.write(text)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [self] in
                try? self.ptyProcess.write("\r")
            }
        } catch {
            streamContinuation = nil
            continuation.yield(.error(error.localizedDescription))
            continuation.finish()
            resetStreamingState()
            return stream
        }

        // 200ms 폴링 타이머 시작 — main queue에서 실행 (headlessTerminal 스레드 안전)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.2)
        timer.setEventHandler { [weak self] in
            self?.pollStreamingDelta()
        }
        timer.resume()
        streamPollTimer = timer

        // 타임아웃 설정
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.currentMessageId == messageId else { return }
            if self.streamContinuation != nil {
                self.completeStreamingResponse(signal: .idleTimeout)
            }
        }

        return stream
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
        let hasActiveContinuation = responseContinuation != nil || streamContinuation != nil
        DispatchQueue.main.async { [self] in
            pendingApproval = nil
            status = hasActiveContinuation ? .busy : .ready
        }
    }

    /// 세션을 종료한다.
    func stop() {
        DebugLogger.shared.endSession(sessionId: id)
        parser.stopMonitoring()

        // CLI에 종료 명령 시도
        try? ptyProcess.write(adapter.exitCommand + "\r")

        // 1초 후 프로세스 종료
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.ptyProcess.terminate()
        }

        // 세션 종료 시 Cloudflare 터널도 함께 종료
        cloudflare.stop()

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

        // 응답 완료 감지 — 스트리밍/비스트리밍 분기
        parser.onResponseComplete = { [weak self] signal in
            guard let self else { return }
            if self.streamContinuation != nil {
                self.completeStreamingResponse(signal: signal)
            } else {
                self.completeResponse(signal: signal)
            }
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
        if responseContinuation != nil || streamContinuation != nil {
            currentResponseBuffer.append(data)

            // 디버그 로깅: 응답 수집 중 PTY 출력
            DebugLogger.shared.logPTYOutput(
                sessionId: id, rawData: data,
                strippedText: String(data: data, encoding: .utf8)
            )
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
        guard let continuation = responseContinuation else {
            print("[Session] ⚠️ completeResponse: no continuation! signal=\(signal)")
            DebugLogger.shared.logError(sessionId: id, message: "no continuation",
                                         context: "completeResponse signal=\(signal)")
            return
        }
        guard let messageId = currentMessageId else {
            print("[Session] ⚠️ completeResponse: no messageId! signal=\(signal)")
            DebugLogger.shared.logError(sessionId: id, message: "no messageId",
                                         context: "completeResponse signal=\(signal)")
            return
        }

        parser.stopMonitoring()
        responseContinuation = nil
        currentMessageId = nil

        let rawText = String(data: currentResponseBuffer, encoding: .utf8) ?? ""

        // Headless 터미널 버퍼에서 화면 텍스트 읽기 (항상 사용 가능)
        let screenText = readHeadlessBuffer()
        var cleanText = adapter.cleanResponse(screenText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 디버그 로깅: 파싱 결과 (cleanResponse 전후)
        DebugLogger.shared.logParsingResult(
            sessionId: id, screenText: screenText, cleanText: cleanText,
            adapterType: adapter.modelId, context: "completeResponse"
        )
        DebugLogger.shared.logCompletionDetected(
            sessionId: id, signal: "\(signal)", screenText: screenText,
            cleanText: cleanText, context: "completeResponse"
        )

        // 빈 응답일 때 에러 감지 — TUI chrome 필터가 걸러낸 에러 메시지 복구
        if cleanText.isEmpty, let errorMsg = adapter.detectError(screenText) {
            cleanText = errorMsg
        }

        // 빈 응답일 때 콘솔 경고
        if cleanText.isEmpty {
            print("[Session] ⚠️ Empty cleanText. Signal: \(signal)")
            DebugLogger.shared.logError(sessionId: id, message: "빈 응답",
                                         context: "completeResponse signal=\(signal)")
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

    // MARK: - Streaming Internals

    /// 폴링 타이머에서 호출: 헤드리스 버퍼 스냅샷 → cleanResponse() → diff → delta 전송.
    private func pollStreamingDelta() {
        guard let continuation = streamContinuation else { return }

        let screenText = readHeadlessBuffer()
        let cleanText = Self.filterStreamingNoise(
            adapter.cleanResponse(screenText)
        )

        let currentLength = cleanText.count

        // 디버그 로깅: 스트리밍 폴링 상태 (빈 응답 대기 중일 때)
        if DebugLogger.shared.isEnabled, cleanText.isEmpty, streamSentLength == 0,
           let start = messageStartTime {
            let elapsed = Date().timeIntervalSince(start)
            // 5초마다 기록 (너무 빈번한 로깅 방지)
            if Int(elapsed) % 5 == 0, Int(elapsed) > 0 {
                DebugLogger.shared.logScreenBuffer(
                    sessionId: id, screenText: screenText,
                    context: "streaming_poll_waiting_\(String(format: "%.0f", elapsed))s"
                )
            }
        }

        // 이전 턴 응답이 그대로 반환된 경우 스킵 (Codex backup/restore 등).
        // baseline과 동일하면 아직 새 응답이 시작되지 않은 것.
        // 다른 내용이 나타나면 baseline을 클리어하여 이후 정상 처리.
        if let baseline = streamBaselineText, !baseline.isEmpty {
            let trimmedClean = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedClean == baseline && streamSentLength == 0 {
                return
            } else if trimmedClean != baseline {
                // 내용이 변경됨 → baseline 클리어
                streamBaselineText = nil
            }
        }

        // cleanText가 빈 경우 (thinking/tool use 중이거나 TUI 리드로우) → 스킵
        // scrollback 10000행이 있으므로 scroll-off raw 폴백 불필요
        guard currentLength > streamSentLength else { return }

        // 새 콘텐츠 증가 — delta 전송
        let startIndex = cleanText.index(cleanText.startIndex, offsetBy: streamSentLength)
        let delta = String(cleanText[startIndex...])
        continuation.yield(.delta(delta))
        streamSentLength = currentLength

        // 디버그 로깅: delta 전송
        if DebugLogger.shared.isEnabled, let start = messageStartTime {
            let elapsed = Date().timeIntervalSince(start)
            DebugLogger.shared.logStreamingPoll(
                sessionId: id, cleanText: cleanText, delta: delta,
                sentLength: streamSentLength, totalLength: currentLength, elapsed: elapsed
            )
        }
    }

    /// 스트리밍 응답 완료 핸들러.
    private func completeStreamingResponse(signal: OutputParser.CompletionSignal) {
        guard let continuation = streamContinuation else {
            print("[Session] ⚠️ completeStreamingResponse: no streamContinuation! signal=\(signal)")
            DebugLogger.shared.logError(sessionId: id, message: "no streamContinuation",
                                         context: "completeStreamingResponse signal=\(signal)")
            return
        }
        guard let messageId = currentMessageId else {
            print("[Session] ⚠️ completeStreamingResponse: no messageId! signal=\(signal)")
            DebugLogger.shared.logError(sessionId: id, message: "no messageId",
                                         context: "completeStreamingResponse signal=\(signal)")
            return
        }

        // 폴링 타이머 정지
        streamPollTimer?.cancel()
        streamPollTimer = nil
        parser.stopMonitoring()

        // 최종 버퍼 읽기 + 정리
        let rawText = String(data: currentResponseBuffer, encoding: .utf8) ?? ""
        let screenText = readHeadlessBuffer()

        // .done 응답용 전체 텍스트 (필터 미적용 — 최종 응답은 완전해야 함)
        var fullCleanText = adapter.cleanResponse(screenText)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // 디버그 로깅: 스트리밍 완료 파싱 결과
        DebugLogger.shared.logParsingResult(
            sessionId: id, screenText: screenText, cleanText: fullCleanText,
            adapterType: adapter.modelId, context: "completeStreamingResponse"
        )
        DebugLogger.shared.logCompletionDetected(
            sessionId: id, signal: "\(signal)", screenText: screenText,
            cleanText: fullCleanText, context: "completeStreamingResponse"
        )

        // 빈 응답일 때 에러 감지
        if fullCleanText.isEmpty, let errorMsg = adapter.detectError(screenText) {
            fullCleanText = errorMsg
            DebugLogger.shared.logError(sessionId: id, message: "스트리밍 빈 응답",
                                         context: "completeStreamingResponse signal=\(signal)")
        }

        // 최종 잔여분 전송 — 스트리밍 노이즈 필터 적용 (pollStreamingDelta와 동일 기준)
        // streamSentLength는 filterStreamingNoise 적용 텍스트 기준이므로
        // 최종 delta 계산도 동일 필터를 적용해야 offset이 일관된다.
        let streamFilteredText = Self.filterStreamingNoise(fullCleanText)
        if streamFilteredText.count > streamSentLength {
            let startIndex = streamFilteredText.index(streamFilteredText.startIndex, offsetBy: streamSentLength)
            let remaining = String(streamFilteredText[startIndex...])
            continuation.yield(.delta(remaining))
        }

        let filesChanged = OutputParser.extractChangedFiles(from: rawText)
        let duration = Int((Date().timeIntervalSince(messageStartTime ?? Date())) * 1000)

        let response = MessageResponse(
            messageId: messageId,
            response: ResponseBody(
                result: fullCleanText,
                raw: AppConfig.shared.includeRawOutput ? rawText : nil,
                filesChanged: filesChanged,
                durationMs: duration
            )
        )

        continuation.yield(.done(response))
        continuation.finish()

        // 상태 초기화
        streamContinuation = nil
        currentMessageId = nil
        currentResponseBuffer = Data()
        messageStartTime = nil
        resetStreamingState()

        DispatchQueue.main.async { [self] in
            status = .ready
        }
    }

    /// 스트리밍 상태를 초기화한다.
    private func resetStreamingState() {
        streamSentLength = 0
        streamBaselineText = nil
        streamPollTimer?.cancel()
        streamPollTimer = nil
    }

    /// 스트리밍 전용 노이즈 필터.
    /// cleanResponse() 결과에서 스트리밍 중에만 제거해야 하는 패턴을 필터링한다.
    /// ⎿ (도구 출력) 줄은 일반 모드 최종 응답에서는 포함될 수 있으므로 여기서만 제거.
    static func filterStreamingNoise(_ text: String) -> String {
        text.components(separatedBy: "\n")
            .filter { line in
                let t = line.trimmingCharacters(in: .whitespaces)
                // ⎿ 도구 출력 줄 제거
                if t.hasPrefix("⎿") { return false }
                return true
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 경량 TUI chrome 필터 (스크롤 오프 폴백용).
    /// 스트리밍 중 빈번한 TUI 패턴만 제거한다. 어댑터별 matchesTUIChrome()보다 보수적.
    static func lightweightTUIChromeFilter(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let filtered = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return true }
            let lowered = trimmed.lowercased()

            // 공통 TUI chrome 패턴
            let chromePatterns = [
                "esc to interrupt", "esc to cancel",
                "? for shortcuts", "shift+tab",
                "type your message",
                "streaming…", "flowing…", "thinking…", "processing…",
                "reading…", "writing…", "searching…", "analyzing…",
                "thinking with high effort",    // thinking effort 표시
                "thinking with standard effort",
                "ctrl+o to expand",        // 도구 사용 확장 힌트
                "ctrl+r to expand",        // 읽기 확장 힌트
            ]
            for pattern in chromePatterns {
                if lowered.contains(pattern) { return false }
            }

            // 상태바 삼각형 마커
            let statusBarChars: Set<Character> = ["⏵", "▶", "►", "⏸", "▸", "⏩"]
            if let first = trimmed.first, statusBarChars.contains(first) {
                return false
            }

            // 스피너 접두사 줄 (thinking 인디케이터)
            let spinnerChars: Set<Character> = [
                "✳", "✶", "✻", "✽", "✢", "·", "◉", "○", "◍", "◎", "●",
                "◐", "◑", "◒", "◓", "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"
            ]
            if let first = trimmed.first, spinnerChars.contains(first) {
                return false
            }

            // ⎿ 도구 출력 줄
            if trimmed.hasPrefix("⎿") { return false }

            // 토큰 카운트 줄
            if let regex = try? NSRegularExpression(pattern: "^\\d+\\.?\\d*[kK]?\\s+tokens?", options: []),
               regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)) != nil {
                return false
            }

            return true
        }
        return filtered.joined(separator: "\n")
    }

    /// Headless 터미널 버퍼에서 전체 텍스트를 읽는다 (scrollback 포함).
    /// getScrollInvariantLine()을 사용하여 visible 영역 밖으로 스크롤된 내용도 포함한다.
    /// 이렇게 해야 500행을 초과하는 긴 응답도 완전히 읽을 수 있다.
    func readHeadlessBuffer() -> String {
        var lines: [String] = []
        var row = 0
        while let line = headlessTerminal.getScrollInvariantLine(row: row) {
            lines.append(line.translateToString(trimRight: true))
            row += 1
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
