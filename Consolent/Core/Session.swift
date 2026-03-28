import Foundation
import SwiftTerm
import Combine

/// 단일 Claude Code 세션.
/// PTY 프로세스 + 출력 버퍼 + 상태 + 응답 감지를 관리한다.
final class Session: ObservableObject, Identifiable, @unchecked Sendable {

    // MARK: - Types

    /// SDK 모드 채팅 버블 UI용 메시지 모델
    struct ChatMessage: Identifiable, Sendable {
        enum Role: Sendable { case user, assistant, system }
        let id = UUID()
        let role: Role
        let text: String
    }

    enum Status: String, Codable, Sendable {
        case stopped        // 프로세스 없이 대기 중 (명시적 중지 또는 복원 대기)
        case initializing
        case ready
        case busy
        case waitingApproval = "waiting_approval"
        case error
        case terminated
    }

    struct Config: Codable {
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

        // MARK: SDK 모드 (Agent SDK 기반)
        /// SDK 모드 활성화. PTY 대신 Agent SDK 브릿지 서버를 실행한다.
        var sdkEnabled: Bool = false
        /// SDK 브릿지 서버 HTTP 포트 (기본 8788).
        var sdkPort: Int = 8788
        /// SDK에서 사용할 모델 (예: "claude-sonnet-4-20250514").
        var sdkModel: String? = nil
        /// SDK 퍼미션 모드 (예: "acceptEdits", "bypassPermissions").
        var sdkPermissionMode: String = "acceptEdits"

        // MARK: Gemini stream-json 모드
        /// Gemini stream-json 모드 활성화. PTY 대신 Gemini 브릿지 서버를 실행한다.
        var geminiStreamEnabled: Bool = false
        /// Gemini 브릿지 서버 HTTP 포트 (기본 8789).
        var geminiStreamPort: Int = 8789

        // MARK: Codex app-server 모드
        /// Codex app-server 모드 활성화. PTY 대신 Codex 브릿지 서버를 실행한다.
        var codexAppServerEnabled: Bool = false
        /// Codex 브릿지 서버 HTTP 포트 (기본 8790).
        var codexAppServerPort: Int = 8790
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

    @Published private(set) var status: Status
    @Published private(set) var pendingApproval: OutputParser.ApprovalRequest? = nil
    @Published private(set) var messageCount: Int = 0

    /// 전체 출력 버퍼 (ANSI 포함 원본)
    @Published private(set) var outputBuffer: Data = Data()

    /// SDK 모드 채팅 메시지 목록 (버블 UI용)
    @Published private(set) var chatMessages: [ChatMessage] = []

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

    /// SDK 모드 활성 여부 (sdkEnabled + 어댑터가 SDK 지원)
    var isSDKMode: Bool { config.sdkEnabled && adapter.supportsSDKMode }

    /// SDK 브릿지 서버 URL (SDK 모드 활성 시)
    var sdkServerURL: String? {
        isSDKMode ? "http://localhost:\(config.sdkPort)" : nil
    }

    /// Gemini stream-json 모드 활성 여부
    var isGeminiStreamMode: Bool { config.geminiStreamEnabled && adapter.supportsGeminiStreamMode }

    /// Gemini 브릿지 서버 URL (Gemini stream 모드 활성 시)
    var geminiStreamServerURL: String? {
        isGeminiStreamMode ? "http://localhost:\(config.geminiStreamPort)" : nil
    }

    /// Codex app-server 모드 활성 여부
    var isCodexAppServerMode: Bool { config.codexAppServerEnabled && adapter.supportsCodexAppServerMode }

    /// Codex 브릿지 서버 URL (Codex app-server 모드 활성 시)
    var codexAppServerURL: String? {
        isCodexAppServerMode ? "http://localhost:\(config.codexAppServerPort)" : nil
    }

    /// 어떤 브릿지 서버든 활성 여부
    var isBridgeMode: Bool { isSDKMode || isGeminiStreamMode || isCodexAppServerMode }

    /// 활성 브릿지 서버 URL
    var bridgeServerURL: String? {
        if isSDKMode { return sdkServerURL }
        if isGeminiStreamMode { return geminiStreamServerURL }
        if isCodexAppServerMode { return codexAppServerURL }
        return nil
    }

    // 메시지 응답 대기용
    private var responseContinuation: CheckedContinuation<MessageResponse, Error>?
    private var currentMessageId: String?
    private var currentResponseBuffer = Data()
    private var messageStartTime: Date?

    // SDK 모드 전용 상태
    private var sdkBridgeProcess: Process?
    private var sdkBridgeStdoutPipe: Pipe?
    private var sdkBridgeStderrPipe: Pipe?

    // Gemini stream 모드 전용 상태
    private var geminiBridgeProcess: Process?
    private var geminiBridgeStdoutPipe: Pipe?

    // Codex app-server 모드 전용 상태
    private var codexBridgeProcess: Process?
    private var codexBridgeStdoutPipe: Pipe?

    /// 브릿지 에러 메시지 (채팅 뷰 에러 표시용)
    @Published private(set) var bridgeError: String? = nil

    /// 브릿지/채널 서버 포트 충돌 정보. 충돌 해결 UI에 사용.
    @Published private(set) var portConflict: PortConflictInfo? = nil

    /// 자동 강제 복구가 이미 시도된 경우 true. 무한 루프 방지용.
    /// stopProcess() 호출 시(사용자가 명시적으로 연결 끊기) 초기화된다.
    private var autoRecoveryAttempted = false

    // 스트리밍 전용 상태
    private var streamContinuation: AsyncStream<StreamEvent>.Continuation?
    private var streamSentLength: Int = 0
    private var streamPollTimer: DispatchSourceTimer?
    /// 메시지 전송 시점의 cleanResponse 결과 (이전 턴의 응답).
    /// 스트리밍 폴링에서 이전 응답이 그대로 반환되는 것을 감지하여 스킵하는 데 사용.
    private var streamBaselineText: String?

    // MARK: - Init

    init(id: String? = nil, config: Config, initialStatus: Status = .initializing) {
        self.id = id ?? "s_\(UUID().uuidString.prefix(8).lowercased())"
        self.config = config
        self.adapter = config.cliType.createAdapter()
        self.name = config.name ?? config.cliType.rawValue
        self.createdAt = Date()
        self.status = initialStatus
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

    /// 세션을 시작한다. 브릿지 모드면 브릿지 서버 실행, 아니면 PTY에서 CLI 실행.
    func start() async throws {
        // .stopped 또는 .error 상태에서 재시작 시 콜백 재연결 + initializing으로 리셋
        // .error: 브릿지 시작 실패 후 사용자가 수동으로 재연결 시도하는 경우
        await MainActor.run {
            if status == .stopped || status == .error {
                // 이전 에러 상태 초기화
                bridgeError = nil
                portConflict = nil
                // PTY 콜백 재연결 (stopProcess() 이후 재시작 시 필요)
                setupCallbacks()
                status = .initializing
            }
        }

        // SDK 모드: Python 브릿지 서버를 실행하고 ready 대기
        if isSDKMode {
            do {
                try await startSDKBridge()
            } catch {
                // 포트 충돌 감지
                await detectPortConflict(port: config.sdkPort)
                throw error
            }
            return
        }

        // Gemini stream-json 모드
        if isGeminiStreamMode {
            do {
                try await startGeminiBridge()
            } catch {
                let msg = bridgeErrorDescription(error)
                await MainActor.run {
                    self.bridgeError = msg
                    self.chatMessages.append(ChatMessage(role: .system, text: "❌ Gemini 브릿지 시작 실패"))
                    self.chatMessages.append(ChatMessage(role: .system, text: msg))
                    self.status = .error
                }
                // 포트 충돌 감지
                await detectPortConflict(port: config.geminiStreamPort)
            }
            return
        }

        // Codex app-server 모드
        if isCodexAppServerMode {
            do {
                try await startCodexBridge()
            } catch {
                let msg = bridgeErrorDescription(error)
                await MainActor.run {
                    self.bridgeError = msg
                    self.chatMessages.append(ChatMessage(role: .system, text: "❌ Codex 브릿지 시작 실패"))
                    self.chatMessages.append(ChatMessage(role: .system, text: msg))
                    self.status = .error
                }
                // 포트 충돌 감지
                await detectPortConflict(port: config.codexAppServerPort)
            }
            return
        }

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
        do {
            try ptyProcess.start(
                executable: config.shell,
                args: shellArgs,
                cwd: config.workingDirectory,
                env: effectiveEnv.isEmpty ? nil : effectiveEnv
            )
        } catch {
            print("[Session] PTY 시작 실패: \(error)")
            await MainActor.run { self.status = .error }
            throw error
        }

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
    func sendMessage(text: String, systemPrompt: String? = nil, imagePaths: [String]? = nil, timeout: TimeInterval = 300) async throws -> MessageResponse {
        // SDK 모드: 브릿지 서버에 HTTP 요청
        if isSDKMode {
            return try await sendMessageSDK(text: text, systemPrompt: systemPrompt, imagePaths: imagePaths, timeout: timeout)
        }

        // Gemini stream 모드 또는 Codex app-server 모드: 브릿지 HTTP 요청
        if isGeminiStreamMode {
            return try await sendMessageBridgeHTTP(port: config.geminiStreamPort, text: text, systemPrompt: systemPrompt, timeout: timeout)
        }
        if isCodexAppServerMode {
            return try await sendMessageBridgeHTTP(port: config.codexAppServerPort, text: text, systemPrompt: systemPrompt, timeout: timeout)
        }

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
    func sendMessageStreaming(text: String, systemPrompt: String? = nil, imagePaths: [String]? = nil, timeout: TimeInterval = 300) -> AsyncStream<StreamEvent> {
        // SDK 모드: 브릿지 서버에 SSE 스트리밍 요청
        if isSDKMode {
            return sendMessageStreamingSDK(text: text, systemPrompt: systemPrompt, imagePaths: imagePaths, timeout: timeout)
        }

        // Gemini stream 또는 Codex app-server 모드: 브릿지 HTTP 스트리밍
        if isGeminiStreamMode {
            return sendMessageStreamingBridgeHTTP(port: config.geminiStreamPort, text: text, systemPrompt: systemPrompt, timeout: timeout)
        }
        if isCodexAppServerMode {
            return sendMessageStreamingBridgeHTTP(port: config.codexAppServerPort, text: text, systemPrompt: systemPrompt, timeout: timeout)
        }

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

        if isSDKMode {
            stopSDKBridge()
            return
        }

        if isGeminiStreamMode {
            stopGeminiBridge()
            return
        }

        if isCodexAppServerMode {
            stopCodexBridge()
            return
        }

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

    /// 프로세스를 중지하되 세션 객체는 유지한다 (.stopped 상태).
    /// 메뉴에서 "세션 중지" 또는 복원 전 초기 상태로 사용.
    func stopProcess() {
        DebugLogger.shared.endSession(sessionId: id)

        if isSDKMode {
            stopSDKBridge()
        } else if isGeminiStreamMode {
            stopGeminiBridge()
        } else if isCodexAppServerMode {
            stopCodexBridge()
        } else {
            parser.stopMonitoring()
            try? ptyProcess.write(adapter.exitCommand + "\r")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.ptyProcess.terminate()
            }
        }

        cloudflare.stop()

        // 사용자가 명시적으로 연결을 끊으면 자동 강제 복구 시도 횟수를 초기화한다.
        autoRecoveryAttempted = false

        DispatchQueue.main.async { [self] in
            status = .stopped
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
                    // stopProcess()가 .stopped로 설정한 경우 덮어쓰지 않음
                    // (의도적 중지 vs 예기치 않은 종료 구분)
                    if self.status != .stopped {
                        self.status = .terminated
                    }
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
    case sdkBridgeStartFailed(reason: String)
    case sdkRequestFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .notReady(let status): return "Session is not ready (status: \(status.rawValue))"
        case .noSuchApproval(let id): return "No pending approval with id: \(id)"
        case .timeout: return "Operation timed out"
        case .sdkBridgeStartFailed(let reason): return "SDK bridge start failed: \(reason)"
        case .sdkRequestFailed(let reason): return "SDK request failed: \(reason)"
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

// MARK: - SDK Mode Implementation

extension Session {

    /// SDK 브릿지 서버 실행 경로를 찾는다.
    private var sdkBridgePath: String {
        let fm = FileManager.default

        // 1. 앱 번들 내 Resources/sdk-bridge/sdk_bridge.py
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("sdk-bridge/sdk_bridge.py").path
            if fm.fileExists(atPath: bundled) {
                return bundled
            }
        }
        // 2. 앱 번들 내 Resources (flat)
        if let bundled = Bundle.main.path(forResource: "sdk_bridge", ofType: "py") {
            return bundled
        }
        // 3. Consolent 프로젝트 소스 트리 (개발 환경)
        //    실행 파일 위치에서 프로젝트 루트를 추정
        let execURL = Bundle.main.bundleURL
        // .app/Contents/MacOS/ → 3단계 상위 = .app, 빌드 폴더 기준으로 프로젝트 루트 탐색
        var searchDir = execURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = searchDir.appendingPathComponent("tools/sdk-bridge/sdk_bridge.py").path
            if fm.fileExists(atPath: candidate) {
                return candidate
            }
            searchDir = searchDir.deletingLastPathComponent()
        }
        // 4. 작업 디렉토리 기준
        let cwdPath = (config.workingDirectory as NSString)
            .appendingPathComponent("tools/sdk-bridge/sdk_bridge.py")
        if fm.fileExists(atPath: cwdPath) {
            return cwdPath
        }
        // 5. 폴백
        return "sdk_bridge.py"
    }

    /// Python 3.10+ 바이너리 경로를 찾는다.
    /// claude-agent-sdk는 Python 3.10 이상을 요구한다.
    private func findPythonPath() -> String {
        // 버전별 후보 (높은 버전 우선)
        let candidates = [
            "/opt/homebrew/bin/python3.13",
            "/opt/homebrew/bin/python3.12",
            "/opt/homebrew/bin/python3.11",
            "/opt/homebrew/bin/python3.10",
            "/usr/local/bin/python3.13",
            "/usr/local/bin/python3.12",
            "/usr/local/bin/python3.11",
            "/usr/local/bin/python3.10",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path),
               checkPythonVersion(path: path, minMajor: 3, minMinor: 10) {
                return path
            }
        }

        // login shell에서 python3 검색 후 버전 확인
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-li", "-c", "which python3"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, process.terminationStatus == 0,
               checkPythonVersion(path: path, minMajor: 3, minMinor: 10) {
                return path
            }
        } catch {}

        // 시스템 python3 (버전 미달일 수 있음 — ensureSDKVenv에서 에러 처리)
        return "/usr/bin/python3"
    }

    /// Python 바이너리의 버전이 최소 요구사항을 충족하는지 확인한다.
    private func checkPythonVersion(path: String, minMajor: Int, minMinor: Int) -> Bool {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["--version"]
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            // "Python 3.12.4" 형태 파싱
            let parts = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "Python ", with: "")
                .split(separator: ".")
            guard parts.count >= 2,
                  let major = Int(parts[0]),
                  let minor = Int(parts[1]) else { return false }
            return major > minMajor || (major == minMajor && minor >= minMinor)
        } catch {
            return false
        }
    }

    /// SDK venv의 Python 경로
    private var sdkVenvPythonPath: String {
        let venvPath = AppConfig.shared.sdkVenvPath
        return (venvPath as NSString).appendingPathComponent("bin/python3")
    }

    /// venv가 유효한지 확인 (python3 바이너리 존재)
    var isSDKVenvReady: Bool {
        FileManager.default.isExecutableFile(atPath: sdkVenvPythonPath)
    }

    /// [정적] 브릿지 venv 설치 여부 확인 (Settings UI 등 인스턴스 없이 사용)
    static var isBridgeVenvReady: Bool {
        let venvPath = AppConfig.shared.sdkVenvPath
        let pythonPath = (venvPath as NSString).appendingPathComponent("bin/python3")
        return FileManager.default.isExecutableFile(atPath: pythonPath)
    }

    /// [정적] 브릿지 venv 설치 (Settings UI에서 세션 없이 호출 가능)
    static func installBridgeVenv() async throws {
        let tempConfig = Session.Config(workingDirectory: NSHomeDirectory())
        let tempSession = Session(config: tempConfig)
        try await tempSession.ensureSDKVenv()
    }

    /// uv 바이너리 경로를 찾는다.
    private func findUVPath() -> String? {
        let candidates = [
            NSHomeDirectory() + "/.local/bin/uv",
            "/opt/homebrew/bin/uv",
            "/usr/local/bin/uv",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // login shell에서 검색
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-li", "-c", "which uv"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty, process.terminationStatus == 0 {
                return path
            }
        } catch {}
        return nil
    }

    /// SDK venv를 생성하고 의존성을 설치한다.
    /// 1) Python 3.10+ 있으면 → python -m venv + pip install
    /// 2) Python 3.10 미만이면 → uv 있으면 uv로 자동 설치, 없으면 에러 + 안내
    func ensureSDKVenv() async throws {
        let venvPath = AppConfig.shared.sdkVenvPath
        let fm = FileManager.default

        // venv 이미 유효하면 스킵
        if isSDKVenvReady {
            print("[SDK] venv 이미 존재: \(venvPath)")
            return
        }

        // 부모 디렉토리 생성
        let parentDir = (venvPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parentDir) {
            try fm.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        // Python 3.10+ 확인
        let pythonPath = findPythonPath()
        let hasPython310 = checkPythonVersion(path: pythonPath, minMajor: 3, minMinor: 10)

        if hasPython310 {
            // Python 3.10+ 있음 → 표준 venv + pip
            try await ensureSDKVenvWithPip(venvPath: venvPath)
        } else if let uvPath = findUVPath() {
            // Python 구버전이지만 uv 있음 → uv로 Python 3.12 자동 설치
            appendSystemLog("[SYSTEM] 시스템 Python이 3.10 미만입니다. uv로 Python 3.12를 자동 설치합니다.\n")
            try await ensureSDKVenvWithUV(uvPath: uvPath, venvPath: venvPath)
        } else {
            // Python 구버전 + uv 없음 → 에러 + 안내
            appendSystemLog("""
            [ERROR] Python 3.10 이상이 필요하지만 시스템에 3.9 이하만 설치되어 있습니다.

            다음 중 하나를 실행하세요:
              1) brew install uv     ← uv가 Python 3.12를 자동 설치합니다 (권장)
              2) brew install python3  ← Python 3.12를 직접 설치합니다

            """)
            throw SessionError.sdkBridgeStartFailed(
                reason: "Python 3.10+ 필요. 'brew install uv' (권장) 또는 'brew install python3'을 실행하세요."
            )
        }
    }

    /// uv 기반 venv 생성 + 의존성 설치.
    /// Python 3.12를 자동 다운로드하므로 시스템 Python 버전에 의존하지 않는다.
    private func ensureSDKVenvWithUV(uvPath: String, venvPath: String) async throws {
        // 1. uv venv --python 3.12
        appendSystemLog("[SYSTEM] uv로 Python 3.12 가상환경 생성 중...\n")
        print("[SDK] uv venv --python 3.12 \(venvPath)")

        let venvResult = try await runProcess(
            path: uvPath,
            arguments: ["venv", "--python", "3.12", venvPath],
            showOutput: true
        )
        guard venvResult == 0 else {
            throw SessionError.sdkBridgeStartFailed(reason: "uv venv 생성 실패 (exit \(venvResult))")
        }

        // 2. uv pip install --python <venv-python>
        appendSystemLog("[SYSTEM] 의존성 설치 중 (claude-agent-sdk, aiohttp)...\n")
        print("[SDK] uv pip install claude-agent-sdk aiohttp")

        let installResult = try await runProcess(
            path: uvPath,
            arguments: ["pip", "install",
                        "--python", sdkVenvPythonPath,
                        "claude-agent-sdk", "aiohttp"],
            showOutput: true
        )
        guard installResult == 0 else {
            throw SessionError.sdkBridgeStartFailed(reason: "uv pip install 실패 (exit \(installResult))")
        }

        appendSystemLog("[SYSTEM] SDK 가상환경 설정 완료 ✓\n")
    }

    /// pip 기반 폴백. 시스템에 Python 3.10+가 필요하다.
    private func ensureSDKVenvWithPip(venvPath: String) async throws {
        let pythonPath = findPythonPath()
        guard checkPythonVersion(path: pythonPath, minMajor: 3, minMinor: 10) else {
            appendSystemLog("[ERROR] Python 3.10+ 필요. uv 또는 Python 3.10+을 설치하세요.\n  brew install uv  (권장)\n  brew install python3\n")
            throw SessionError.sdkBridgeStartFailed(
                reason: "Python 3.10+ 필요. 'brew install uv' 또는 'brew install python3'으로 설치하세요."
            )
        }

        // 1. venv 생성
        appendSystemLog("[SYSTEM] Python venv 생성 중...\n")

        let venvResult = try await runProcess(
            path: pythonPath,
            arguments: ["-m", "venv", venvPath],
            showOutput: false
        )
        guard venvResult == 0 else {
            throw SessionError.sdkBridgeStartFailed(reason: "venv 생성 실패")
        }

        // 2. pip 업그레이드
        let venvPython = (venvPath as NSString).appendingPathComponent("bin/python3")
        appendSystemLog("[SYSTEM] pip 업그레이드 중...\n")
        _ = try await runProcess(
            path: venvPython,
            arguments: ["-m", "pip", "install", "--upgrade", "pip"],
            showOutput: false
        )

        // 3. 의존성 설치
        let pipPath = (venvPath as NSString).appendingPathComponent("bin/pip")
        appendSystemLog("[SYSTEM] 의존성 설치 중 (claude-agent-sdk, aiohttp)...\n")

        let installResult = try await runProcess(
            path: pipPath,
            arguments: ["install", "claude-agent-sdk", "aiohttp"],
            showOutput: true
        )
        guard installResult == 0 else {
            throw SessionError.sdkBridgeStartFailed(reason: "pip install 실패")
        }

        appendSystemLog("[SYSTEM] SDK 가상환경 설정 완료 ✓\n")
    }

    /// 외부 프로세스를 실행하고 종료 코드를 반환한다.
    private func runProcess(path: String, arguments: [String], showOutput: Bool) async throws -> Int32 {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = showOutput ? stdoutPipe : FileHandle.nullDevice
        process.standardError = stderrPipe

        if showOutput {
            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let self else { return }
                DispatchQueue.main.async {
                    self.outputBuffer.append(data)
                    self.onTerminalOutput?(data)
                }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            DispatchQueue.main.async {
                self.outputBuffer.append(data)
                self.onTerminalOutput?(data)
            }
        }

        try process.run()

        // 비동기 대기
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { proc in
                if showOutput {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                }
                stderrPipe.fileHandleForReading.readabilityHandler = nil
                continuation.resume(returning: proc.terminationStatus)
            }
        }
    }

    /// @@CONSOLENT@@ 라인을 ChatMessage로 변환한다. UI 표시용.
    private func parseChatMessage(from line: String) -> ChatMessage? {
        let prefix = "@@CONSOLENT@@"
        guard line.hasPrefix(prefix) else { return nil }
        let jsonStr = String(line.dropFirst(prefix.count))
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let type = json["type"],
              let content = json["content"] else { return nil }
        switch type {
        case "user":      return ChatMessage(role: .user, text: content)
        case "assistant": return ChatMessage(role: .assistant, text: content)
        case "system":    return ChatMessage(role: .system, text: content)
        default:          return nil
        }
    }

    /// SDK 브릿지 서버의 stdout 라인을 파싱하여 포맷된 로그를 반환한다.
    /// @@CONSOLENT@@{"type":"user","content":"..."} 형태를 파싱.
    /// 매칭되지 않는 라인은 nil 반환 (표시하지 않음).
    private func formatSDKLog(_ line: String) -> String? {
        let prefix = "@@CONSOLENT@@"
        guard line.hasPrefix(prefix) else { return nil }

        let jsonStr = String(line.dropFirst(prefix.count))
        guard let data = jsonStr.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let type = json["type"],
              let content = json["content"] else {
            return nil
        }

        switch type {
        case "system":
            return "─── \(content)\n"
        case "user":
            let preview = content.count > 200 ? String(content.prefix(200)) + "..." : content
            return "\n▶ USER: \(preview)\n"
        case "assistant":
            return "◀ CLAUDE:\n\(content)\n"
        case "assistant_done":
            return "───────────────────────────────\n"
        case "result":
            return nil
        case "tool_use":
            return "  🔧 \(content)\n"
        case "tool_result":
            let preview = content.count > 300 ? String(content.prefix(300)) + "..." : content
            return "  ↳ \(preview)\n"
        case "thinking":
            return "  💭 \(content)\n"
        default:
            return "[\(type)] \(content)\n"
        }
    }

    /// outputBuffer에 시스템 로그를 추가한다.
    private func appendSystemLog(_ message: String) {
        guard let data = message.data(using: .utf8) else { return }
        DispatchQueue.main.async { [self] in
            outputBuffer.append(data)
            onTerminalOutput?(data)
        }
    }

    /// SDK 브릿지 서버를 시작한다.
    private func startSDKBridge() async throws {
        // venv 준비 (없으면 자동 생성 + 의존성 설치)
        try await ensureSDKVenv()

        let pythonPath = sdkVenvPythonPath
        let bridgePath = sdkBridgePath
        let port = config.sdkPort

        print("[SDK] 브릿지 서버 시작: \(pythonPath) \(bridgePath) --port \(port)")

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: pythonPath)
        var args = [bridgePath, "--port", String(port), "--cwd", config.workingDirectory]
        if let model = config.sdkModel {
            args += ["--model", model]
        }
        args += ["--permission-mode", config.sdkPermissionMode]
        args += ["--log-level", AppConfig.shared.bridgeLogLevel]
        process.arguments = args
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)

        // stdout: @@CONSOLENT@@ 라인을 파싱하여 포맷된 로그만 표시. 나머지는 무시.
        nonisolated(unsafe) var stdoutBuffer = ""
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }

            stdoutBuffer += text
            // 줄 단위 처리
            while let newlineRange = stdoutBuffer.range(of: "\n") {
                let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineRange.lowerBound])
                stdoutBuffer = String(stdoutBuffer[newlineRange.upperBound...])

                let chatMsg = self.parseChatMessage(from: line)
                guard let formatted = self.formatSDKLog(line) else { continue }
                guard let logData = formatted.data(using: .utf8) else { continue }
                DispatchQueue.main.async {
                    self.outputBuffer.append(logData)
                    self.onTerminalOutput?(logData)
                    if let msg = chatMsg { self.chatMessages.append(msg) }
                }
            }
        }
        // stderr는 조용히 무시 (에러 시에만 표시)
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        do {
            try process.run()
        } catch {
            throw SessionError.sdkBridgeStartFailed(reason: error.localizedDescription)
        }

        sdkBridgeProcess = process
        sdkBridgeStdoutPipe = stdoutPipe
        sdkBridgeStderrPipe = stderrPipe

        // 프로세스 종료 감지
        // .stopped: 사용자가 명시적으로 연결 끊기 → 에러 표시 안 함
        // .terminated: 이미 다른 경로로 종료 처리됨
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.status != .terminated && self.status != .stopped {
                    self.status = .error
                    print("[SDK] 브릿지 프로세스 비정상 종료")
                }
            }
        }

        // health 엔드포인트 폴링으로 ready 대기
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        for i in 0..<60 {  // 최대 30초
            try await Task.sleep(nanoseconds: 500_000_000)
            if !process.isRunning { throw SessionError.sdkBridgeStartFailed(reason: "프로세스 종료됨") }
            do {
                let (data, response) = try await URLSession.shared.data(from: healthURL)
                if let _ = response as? HTTPURLResponse,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let st = json["status"] as? String {
                    if st == "ready" {
                        await MainActor.run { self.status = .ready }
                        DebugLogger.shared.startSession(sessionId: id, cliType: config.cliType.rawValue, name: name)
                        print("[SDK] 브릿지 서버 ready (포트 \(port), \(i+1)회 폴링)")
                        return
                    } else if st == "error", let errMsg = json["error"] as? String {
                        process.terminate()
                        throw SessionError.sdkBridgeStartFailed(reason: "SDK 초기화 실패: \(errMsg)")
                    }
                    // "initializing" or "busy" → 계속 대기
                }
            } catch let e as SessionError {
                throw e  // 초기화 실패는 재전파
            } catch {
                // 아직 서버가 올라오지 않음 (connection refused 등) — 계속 대기
            }
        }
        // 타임아웃
        process.terminate()
        throw SessionError.sdkBridgeStartFailed(reason: "30초 내 ready 되지 않음")
    }

    /// SDK 브릿지 서버를 종료한다.
    private func stopSDKBridge() {
        // disconnect 엔드포인트 호출 시도
        if let url = URL(string: "http://127.0.0.1:\(config.sdkPort)/disconnect") {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 2
            URLSession.shared.dataTask(with: request).resume()
        }

        // 1초 후 강제 종료
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.sdkBridgeProcess?.terminate()
            self?.sdkBridgeProcess = nil
        }

        sdkBridgeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        sdkBridgeStderrPipe?.fileHandleForReading.readabilityHandler = nil
        cloudflare.stop()

        DispatchQueue.main.async { [self] in
            status = .terminated
        }
    }

    /// SDK 모드 동기 메시지 전송.
    private func sendMessageSDK(text: String, systemPrompt: String?, imagePaths: [String]?, timeout: TimeInterval) async throws -> MessageResponse {
        guard status == .ready else {
            throw SessionError.notReady(currentStatus: status)
        }

        let messageId = "m_\(UUID().uuidString.prefix(8).lowercased())"
        await MainActor.run { status = .busy; messageCount += 1 }
        let startTime = Date()

        defer {
            DispatchQueue.main.async { self.status = .ready }
        }

        // Python 서버가 @@CONSOLENT@@ 로 stdout에 로그를 출력하므로
        // Swift 측에서는 직접 outputBuffer에 쓰지 않는다.

        let body = buildChatCompletionsBody(text: text, systemPrompt: systemPrompt, imagePaths: imagePaths, stream: false)
        let url = URL(string: "http://127.0.0.1:\(config.sdkPort)/v1/chat/completions")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SessionError.sdkRequestFailed(reason: errorText)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let firstChoice = choices.first,
              let message = firstChoice["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SessionError.sdkRequestFailed(reason: "응답 파싱 실패")
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)

        return MessageResponse(
            messageId: messageId,
            response: ResponseBody(result: content, raw: String(data: data, encoding: .utf8), filesChanged: [], durationMs: duration)
        )
    }

    /// SDK 모드 스트리밍 메시지 전송.
    private func sendMessageStreamingSDK(text: String, systemPrompt: String?, imagePaths: [String]?, timeout: TimeInterval) -> AsyncStream<StreamEvent> {
        let messageId = "m_\(UUID().uuidString.prefix(8).lowercased())"

        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()

        guard status == .ready else {
            continuation.yield(.error("Session is not ready (status: \(status.rawValue))"))
            continuation.finish()
            return stream
        }

        DispatchQueue.main.async { [self] in
            status = .busy
            messageCount += 1
        }

        let startTime = Date()

        // Python 서버가 @@CONSOLENT@@ 로 stdout에 로그를 출력하므로
        // Swift 측에서는 직접 outputBuffer에 쓰지 않는다.

        let body = buildChatCompletionsBody(text: text, systemPrompt: systemPrompt, imagePaths: imagePaths, stream: true)
        let url = URL(string: "http://127.0.0.1:\(config.sdkPort)/v1/chat/completions")!

        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = timeout

            var fullText = ""

            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)

                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continuation.yield(.error("SDK 서버 응답 오류"))
                    continuation.finish()
                    DispatchQueue.main.async { self.status = .ready }
                    return
                }

                // SSE 라인 단위 파싱
                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))

                    if payload == "[DONE]" {
                        break
                    }

                    guard let jsonData = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let content = delta["content"] as? String else {
                        continue
                    }

                    fullText += content
                    continuation.yield(.delta(content))
                }

                let duration = Int(Date().timeIntervalSince(startTime) * 1000)
                let messageResponse = MessageResponse(
                    messageId: messageId,
                    response: ResponseBody(result: fullText, raw: nil, filesChanged: [], durationMs: duration)
                )
                continuation.yield(.done(messageResponse))

            } catch {
                continuation.yield(.error(error.localizedDescription))
            }

            continuation.finish()
            DispatchQueue.main.async { self.status = .ready }
        }

        return stream
    }

    /// OpenAI chat/completions 요청 바디를 구성한다.
    private func buildChatCompletionsBody(text: String, systemPrompt: String?, imagePaths: [String]?, stream: Bool) -> [String: Any] {
        var messages: [[String: Any]] = []

        // 시스템 프롬프트
        if let sp = systemPrompt, !sp.isEmpty {
            messages.append(["role": "system", "content": sp])
        }

        // 유저 메시지 (이미지 포함 시 Vision 형태)
        if let images = imagePaths, !images.isEmpty {
            var content: [[String: Any]] = []
            for imagePath in images {
                // base64로 인코딩
                if let imageData = try? Data(contentsOf: URL(fileURLWithPath: imagePath)) {
                    let base64 = imageData.base64EncodedString()
                    let ext = (imagePath as NSString).pathExtension.lowercased()
                    let mime = ext == "png" ? "image/png" : ext == "jpg" || ext == "jpeg" ? "image/jpeg" : "image/\(ext)"
                    content.append([
                        "type": "image_url",
                        "image_url": ["url": "data:\(mime);base64,\(base64)"]
                    ])
                }
            }
            content.append(["type": "text", "text": text])
            messages.append(["role": "user", "content": content])
        } else {
            messages.append(["role": "user", "content": text])
        }

        var body: [String: Any] = [
            "messages": messages,
            "stream": stream,
        ]
        if let model = config.sdkModel {
            body["model"] = model
        }
        return body
    }

    // MARK: - Gemini Bridge

    /// Gemini 브릿지 서버를 시작한다 (gemini_bridge.py 서브프로세스).
    private func startGeminiBridge() async throws {
        let bridgePath = findBridgeScript(name: "gemini_bridge.py", folder: "gemini-bridge")
        let pythonPath = sdkVenvPythonPath  // venv 재사용 (aiohttp 설치됨)
        let port = config.geminiStreamPort

        // venv에 aiohttp 설치 (없으면)
        try await ensureVenvWithAiohttp()

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [bridgePath, "--port", String(port), "--cwd", config.workingDirectory,
                             "--log-level", AppConfig.shared.bridgeLogLevel]
        process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)

        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        nonisolated(unsafe) var stdoutBuffer = ""
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            stdoutBuffer += text
            while let newlineRange = stdoutBuffer.range(of: "\n") {
                let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineRange.lowerBound])
                stdoutBuffer = String(stdoutBuffer[newlineRange.upperBound...])
                let chatMsg = self.parseChatMessage(from: line)
                guard let formatted = self.formatSDKLog(line) else { continue }
                guard let logData = formatted.data(using: .utf8) else { continue }
                DispatchQueue.main.async {
                    self.outputBuffer.append(logData)
                    self.onTerminalOutput?(logData)
                    if let msg = chatMsg { self.chatMessages.append(msg) }
                }
            }
        }

        // stderr: 에러 라인을 chatMessages에 표시
        nonisolated(unsafe) var stderrBuffer = ""
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            stderrBuffer += text
            while let newlineRange = stderrBuffer.range(of: "\n") {
                let line = String(stderrBuffer[stderrBuffer.startIndex..<newlineRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stderrBuffer = String(stderrBuffer[newlineRange.upperBound...])
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async {
                    self.chatMessages.append(ChatMessage(role: .system, text: "⚠️ \(line)"))
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw SessionError.sdkBridgeStartFailed(reason: "Gemini 브릿지 시작 실패: \(error.localizedDescription)")
        }

        geminiBridgeProcess = process
        geminiBridgeStdoutPipe = stdoutPipe

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.status != .terminated && self.status != .stopped {
                    self.status = .error
                    self.chatMessages.append(ChatMessage(role: .system, text: "❌ Gemini 브릿지 프로세스가 예상치 않게 종료됐습니다."))
                }
            }
        }

        // /health 폴링으로 ready 대기
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        for i in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if !process.isRunning {
                throw SessionError.sdkBridgeStartFailed(reason: "Gemini 브릿지 프로세스가 시작 중 종료됐습니다. stderr 로그를 확인하세요.")
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: healthURL)
                if let http = response as? HTTPURLResponse, http.statusCode == 200,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let st = json["status"] as? String, st == "ready" {
                    await MainActor.run { self.status = .ready }
                    DebugLogger.shared.startSession(sessionId: id, cliType: config.cliType.rawValue, name: name)
                    print("[Gemini] 브릿지 서버 ready (포트 \(port), \(i+1)회 폴링)")
                    return
                }
            } catch { }
        }
        process.terminate()
        throw SessionError.sdkBridgeStartFailed(reason: "30초 내에 Gemini 브릿지 서버가 준비되지 않았습니다. aiohttp 설치 여부와 포트 \(port) 사용 가능 여부를 확인하세요.")
    }

    /// Gemini 브릿지 서버를 종료한다.
    private func stopGeminiBridge() {
        geminiBridgeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.geminiBridgeProcess?.terminate()
            self?.geminiBridgeProcess = nil
        }
        cloudflare.stop()
        DispatchQueue.main.async { [self] in status = .terminated }
    }

    /// Gemini 브릿지 서버를 내부적으로 정지한다 (status 변경 없음, 재시작용).
    private func stopGeminiBridgeInternal() {
        geminiBridgeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        geminiBridgeProcess?.terminate()
        geminiBridgeProcess = nil
        geminiBridgeStdoutPipe = nil
    }

    // MARK: - Codex Bridge

    /// Codex app-server 브릿지 서버를 시작한다 (codex_bridge.py 서브프로세스).
    private func startCodexBridge() async throws {
        let bridgePath = findBridgeScript(name: "codex_bridge.py", folder: "codex-bridge")
        let pythonPath = sdkVenvPythonPath
        let port = config.codexAppServerPort

        try await ensureVenvWithAiohttp()

        let process = Process()
        let stdoutPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = [bridgePath, "--port", String(port), "--cwd", config.workingDirectory,
                             "--log-level", AppConfig.shared.bridgeLogLevel]
        process.currentDirectoryURL = URL(fileURLWithPath: config.workingDirectory)

        let stderrPipe2 = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe2

        nonisolated(unsafe) var stdoutBuffer = ""
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            stdoutBuffer += text
            while let newlineRange = stdoutBuffer.range(of: "\n") {
                let line = String(stdoutBuffer[stdoutBuffer.startIndex..<newlineRange.lowerBound])
                stdoutBuffer = String(stdoutBuffer[newlineRange.upperBound...])
                let chatMsg = self.parseChatMessage(from: line)
                guard let formatted = self.formatSDKLog(line) else { continue }
                guard let logData = formatted.data(using: .utf8) else { continue }
                DispatchQueue.main.async {
                    self.outputBuffer.append(logData)
                    self.onTerminalOutput?(logData)
                    if let msg = chatMsg { self.chatMessages.append(msg) }
                }
            }
        }

        // stderr: 에러 라인을 chatMessages에 표시
        nonisolated(unsafe) var stderrBuffer2 = ""
        stderrPipe2.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self else { return }
            guard let text = String(data: data, encoding: .utf8) else { return }
            stderrBuffer2 += text
            while let newlineRange = stderrBuffer2.range(of: "\n") {
                let line = String(stderrBuffer2[stderrBuffer2.startIndex..<newlineRange.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                stderrBuffer2 = String(stderrBuffer2[newlineRange.upperBound...])
                guard !line.isEmpty else { continue }
                DispatchQueue.main.async {
                    self.chatMessages.append(ChatMessage(role: .system, text: "⚠️ \(line)"))
                }
            }
        }

        do {
            try process.run()
        } catch {
            throw SessionError.sdkBridgeStartFailed(reason: "Codex 브릿지 시작 실패: \(error.localizedDescription)")
        }

        codexBridgeProcess = process
        codexBridgeStdoutPipe = stdoutPipe

        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            DispatchQueue.main.async {
                if self.status != .terminated && self.status != .stopped {
                    self.status = .error
                    self.chatMessages.append(ChatMessage(role: .system, text: "❌ Codex 브릿지 프로세스가 예상치 않게 종료됐습니다."))
                }
            }
        }

        // /health 폴링으로 ready 대기
        // codex_bridge.py는 HTTP 서버를 먼저 시작하고 핸드셰이크를 나중에 하므로
        // "initializing" → "ready" 또는 "error" 상태 변화를 기다린다.
        let healthURL = URL(string: "http://127.0.0.1:\(port)/health")!
        for i in 0..<60 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if !process.isRunning {
                throw SessionError.sdkBridgeStartFailed(reason: "Codex 브릿지 프로세스가 시작 중 종료됐습니다. stderr 로그를 확인하세요.")
            }
            do {
                let (data, response) = try await URLSession.shared.data(from: healthURL)
                if let http = response as? HTTPURLResponse,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let st = json["status"] as? String ?? ""
                    if http.statusCode == 200, st == "ready" {
                        await MainActor.run { self.status = .ready }
                        DebugLogger.shared.startSession(sessionId: id, cliType: config.cliType.rawValue, name: name)
                        print("[Codex] 브릿지 서버 ready (포트 \(port), \(i+1)회 폴링)")
                        return
                    } else if st == "error", let errMsg = json["error"] as? String {
                        process.terminate()
                        throw SessionError.sdkBridgeStartFailed(reason: "Codex 초기화 실패: \(errMsg)")
                    }
                    // "initializing" 상태면 계속 폴링
                }
            } catch let e as SessionError { throw e }
              catch { }
        }
        process.terminate()
        throw SessionError.sdkBridgeStartFailed(reason: "30초 내에 Codex 브릿지 서버가 준비되지 않았습니다. codex 바이너리 설치 여부와 포트 \(port) 사용 가능 여부를 확인하세요.")
    }

    /// Codex 브릿지 서버를 종료한다.
    private func stopCodexBridge() {
        codexBridgeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.codexBridgeProcess?.terminate()
            self?.codexBridgeProcess = nil
        }
        cloudflare.stop()
        DispatchQueue.main.async { [self] in status = .terminated }
    }

    /// Codex 브릿지 서버를 내부적으로 정지한다 (status 변경 없음, 재시작용).
    private func stopCodexBridgeInternal() {
        codexBridgeStdoutPipe?.fileHandleForReading.readabilityHandler = nil
        codexBridgeProcess?.terminate()
        codexBridgeProcess = nil
        codexBridgeStdoutPipe = nil
    }

    // MARK: - Bridge Restart (공개 API)

    /// 브릿지 서버를 재시작한다. 기존 chatMessages를 초기화하고 새로 시작한다.
    func restartBridge() async {
        guard isGeminiStreamMode || isCodexAppServerMode else { return }

        // 화면 초기화 및 상태 리셋
        await MainActor.run {
            chatMessages = []
            outputBuffer = Data()
            bridgeError = nil
            status = .initializing
        }

        if isGeminiStreamMode {
            stopGeminiBridgeInternal()
            do {
                try await startGeminiBridge()
            } catch {
                let msg = bridgeErrorDescription(error)
                await MainActor.run {
                    self.bridgeError = msg
                    self.chatMessages.append(ChatMessage(role: .system, text: "❌ Gemini 브릿지 재시작 실패"))
                    self.chatMessages.append(ChatMessage(role: .system, text: msg))
                    self.status = .error
                }
                // 포트 충돌 감지
                await detectPortConflict(port: config.geminiStreamPort)
            }
        } else if isCodexAppServerMode {
            stopCodexBridgeInternal()
            do {
                try await startCodexBridge()
            } catch {
                let msg = bridgeErrorDescription(error)
                await MainActor.run {
                    self.bridgeError = msg
                    self.chatMessages.append(ChatMessage(role: .system, text: "❌ Codex 브릿지 재시작 실패"))
                    self.chatMessages.append(ChatMessage(role: .system, text: msg))
                    self.status = .error
                }
                // 포트 충돌 감지
                await detectPortConflict(port: config.codexAppServerPort)
            }
        }
    }

    /// SessionError에서 사람이 읽기 좋은 에러 설명 문자열을 추출한다.
    private func bridgeErrorDescription(_ error: Error) -> String {
        if case .sdkBridgeStartFailed(let reason) = error as? SessionError {
            return reason
        }
        return error.localizedDescription
    }

    /// 지정된 포트의 충돌을 감지하여 portConflict를 설정한다.
    /// 자동 강제 복구 모드가 ON이면 확인 없이 충돌 프로세스를 종료하고 재시작한다.
    private func detectPortConflict(port: Int) async {
        let conflict = await Task.detached(priority: .userInitiated) {
            APIServer.detectConflict(onPort: port)
        }.value
        await MainActor.run {
            self.portConflict = conflict
        }

        // 자동 강제 복구: 충돌이 있고, 설정 ON이며, 이번 세션에서 아직 시도하지 않은 경우
        if conflict != nil && AppConfig.shared.autoForceRecovery && !autoRecoveryAttempted {
            autoRecoveryAttempted = true
            print("[Session:\(name ?? id.description)] 자동 강제 복구: 포트 \(port) 충돌 프로세스 종료 후 재시작")
            try? await resolvePortConflictAndRestart()
        }
    }

    /// 포트 충돌 중인 프로세스를 강제 종료하고 세션을 재시작한다.
    func resolvePortConflictAndRestart() async throws {
        guard let conflict = portConflict else { return }
        // 프로세스 강제 종료
        for pid in conflict.pids {
            kill(pid, SIGKILL)
        }
        // 재시작 전 에러 상태 및 출력 버퍼 초기화
        await MainActor.run {
            self.portConflict = nil
            self.bridgeError = nil
            self.outputBuffer = Data()
            self.chatMessages = []
            self.status = .stopped
        }
        // 잠시 대기 후 재시작
        try await Task.sleep(nanoseconds: 500_000_000)
        try await start()
    }

    // MARK: - Generic Bridge HTTP

    /// Gemini/Codex 브릿지 서버에 동기 HTTP 요청을 보낸다.
    private func sendMessageBridgeHTTP(port: Int, text: String, systemPrompt: String?, timeout: TimeInterval) async throws -> MessageResponse {
        guard status == .ready else {
            throw SessionError.notReady(currentStatus: status)
        }

        let messageId = "m_\(UUID().uuidString.prefix(8).lowercased())"
        await MainActor.run { status = .busy; messageCount += 1 }
        let startTime = Date()

        defer { DispatchQueue.main.async { self.status = .ready } }

        var body: [String: Any] = [
            "messages": [["role": "user", "content": text]],
            "stream": false,
        ]
        if let sp = systemPrompt, !sp.isEmpty {
            body["messages"] = [
                ["role": "system", "content": sp],
                ["role": "user", "content": text],
            ]
        }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = timeout

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let errorText = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw SessionError.sdkRequestFailed(reason: errorText)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw SessionError.sdkRequestFailed(reason: "응답 파싱 실패")
        }

        let duration = Int(Date().timeIntervalSince(startTime) * 1000)
        return MessageResponse(
            messageId: messageId,
            response: ResponseBody(result: content, raw: String(data: data, encoding: .utf8), filesChanged: [], durationMs: duration)
        )
    }

    /// Gemini/Codex 브릿지 서버에 스트리밍 HTTP 요청을 보낸다.
    private func sendMessageStreamingBridgeHTTP(port: Int, text: String, systemPrompt: String?, timeout: TimeInterval) -> AsyncStream<StreamEvent> {
        let messageId = "m_\(UUID().uuidString.prefix(8).lowercased())"
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()

        guard status == .ready else {
            continuation.yield(.error("Session is not ready (status: \(status.rawValue))"))
            continuation.finish()
            return stream
        }

        DispatchQueue.main.async { [self] in
            status = .busy
            messageCount += 1
        }

        let startTime = Date()
        var body: [String: Any] = [
            "messages": [["role": "user", "content": text]],
            "stream": true,
        ]
        if let sp = systemPrompt, !sp.isEmpty {
            body["messages"] = [
                ["role": "system", "content": sp],
                ["role": "user", "content": text],
            ]
        }

        let url = URL(string: "http://127.0.0.1:\(port)/v1/chat/completions")!

        Task {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = timeout

            var fullText = ""
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    continuation.yield(.error("브릿지 서버 응답 오류"))
                    continuation.finish()
                    DispatchQueue.main.async { self.status = .ready }
                    return
                }

                for try await line in bytes.lines {
                    guard line.hasPrefix("data: ") else { continue }
                    let payload = String(line.dropFirst(6))
                    if payload == "[DONE]" { break }
                    guard let jsonData = payload.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                          let choices = json["choices"] as? [[String: Any]],
                          let delta = choices.first?["delta"] as? [String: Any],
                          let content = delta["content"] as? String else { continue }
                    fullText += content
                    continuation.yield(.delta(content))
                }

                let duration = Int(Date().timeIntervalSince(startTime) * 1000)
                continuation.yield(.done(MessageResponse(
                    messageId: messageId,
                    response: ResponseBody(result: fullText, raw: nil, filesChanged: [], durationMs: duration)
                )))
            } catch {
                continuation.yield(.error(error.localizedDescription))
            }
            continuation.finish()
            DispatchQueue.main.async { self.status = .ready }
        }

        return stream
    }

    // MARK: - Bridge script path finder

    /// 브릿지 스크립트 경로를 찾는다 (SDK 브릿지와 동일한 탐색 전략).
    private func findBridgeScript(name: String, folder: String) -> String {
        let fm = FileManager.default

        // 1. 앱 번들
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("\(folder)/\(name)").path
            if fm.fileExists(atPath: bundled) { return bundled }
        }
        if let bundled = Bundle.main.path(forResource: name.replacingOccurrences(of: ".py", with: ""), ofType: "py") {
            return bundled
        }

        // 2. 프로젝트 소스 트리
        var searchDir = Bundle.main.bundleURL.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = searchDir.appendingPathComponent("tools/\(folder)/\(name)").path
            if fm.fileExists(atPath: candidate) { return candidate }
            searchDir = searchDir.deletingLastPathComponent()
        }

        // 3. 작업 디렉토리
        let cwdPath = (config.workingDirectory as NSString).appendingPathComponent("tools/\(folder)/\(name)")
        if fm.fileExists(atPath: cwdPath) { return cwdPath }

        return name
    }

    /// venv에 aiohttp가 설치됐는지 확인하고 없으면 설치한다.
    /// SDK venv(ensureSDKVenv)는 aiohttp도 함께 설치하므로 그것을 재사용한다.
    private func ensureVenvWithAiohttp() async throws {
        try await ensureSDKVenv()
    }
}

