import Foundation
import Vapor

/// 포트 충돌 정보.
struct PortConflictInfo {
    let port: Int
    let pids: [Int32]
    let processCommands: [String]  // 전체 명령어 (예: "node /path/to/server.js")
    let suggestedPort: Int         // 사용 가능한 다음 포트

    /// 표시용 프로세스 이름 (명령어의 바이너리 이름만)
    var displayName: String {
        guard let firstCmd = processCommands.first, !firstCmd.isEmpty else {
            return "알 수 없는 프로세스"
        }
        let binary = firstCmd.components(separatedBy: " ").first ?? firstCmd
        return URL(fileURLWithPath: binary).lastPathComponent
    }

    /// 상세 표시용 (전체 명령어, 너무 길면 자름)
    var displayCommand: String {
        let cmd = processCommands.first ?? ""
        return cmd.count > 80 ? String(cmd.prefix(80)) + "…" : cmd
    }
}

/// 임베디드 Vapor HTTP/WebSocket 서버.
/// macOS 앱 내에서 백그라운드로 동작한다.
final class APIServer: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var serverError: String?
    @Published private(set) var connectionCount = 0
    @Published var portConflict: PortConflictInfo? = nil

    private var app: Application?
    private let sessionManager: SessionManager

    init(sessionManager: SessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    @MainActor
    func setServerError(_ error: String?) {
        self.serverError = error
    }

    // MARK: - Lifecycle

    func start(config: AppConfig) async throws {
        guard !isRunning else { return }

        print("[Consolent API] Starting server on \(config.apiBind):\(config.apiPort)...")

        // macOS 앱 환경에서는 Environment.detect()가 launch argument를 잘못 파싱할 수 있다.
        // 명시적으로 .development 환경을 사용한다.
        let env = Environment(name: "development", arguments: ["vapor"])
        let app = try await Application.make(env)

        // Vapor 내부 로그 레벨 설정
        app.logger.logLevel = .notice

        app.http.server.configuration.hostname = config.apiBind
        app.http.server.configuration.port = config.apiPort
        app.http.server.configuration.serverName = "Consolent"

        // 요청 body 크기 제한 (기본 16KB → 50MB)
        // 이미지 첨부(base64) 요청도 수용할 수 있도록 충분히 확보
        app.routes.defaultMaxBodySize = "50mb"

        // JSON 날짜 포맷
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        ContentConfiguration.global.use(encoder: encoder, for: .json)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        ContentConfiguration.global.use(decoder: decoder, for: .json)

        // 미들웨어
        let authMiddleware = APIAuthMiddleware(apiKey: config.apiKey)
        let authGroup = app.grouped(authMiddleware)

        // 라우트 등록
        registerRoutes(on: authGroup)
        registerOpenAIRoutes(on: authGroup)

        // WebSocket
        registerWebSocket(on: app, apiKey: config.apiKey)

        try await app.startup()
        self.app = app

        await MainActor.run {
            self.isRunning = true
            self.serverError = nil
        }

        print("[Consolent API] Server started successfully on http://\(config.apiBind):\(config.apiPort)")
    }

    func stop() async {
        if let app {
            try? await app.asyncShutdown()
            self.app = nil
        }
        await MainActor.run {
            self.isRunning = false
            self.serverError = nil
        }
        print("[Consolent API] Server stopped")
    }

    // MARK: - 포트 충돌 감지 및 해결

    /// lsof로 해당 포트를 사용 중인 PID 목록을 반환한다.
    static func findPIDs(onPort port: Int) -> [Int32] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", ":\(port)", "-t", "-sTCP:LISTEN"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output
            .components(separatedBy: .newlines)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 > 0 }
            // 중복 제거 (fork된 자식 프로세스가 같은 소켓 공유)
            .reduce(into: [Int32]()) { result, pid in
                if !result.contains(pid) { result.append(pid) }
            }
    }

    /// PID로 전체 명령어를 반환한다 (예: "node /path/to/server.js --port 9999").
    static func processCommand(pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 해당 포트부터 시작해서 사용 가능한 다음 포트를 반환한다.
    static func findAvailablePort(startingFrom port: Int) -> Int {
        var candidate = port + 1
        while candidate < 65535 {
            let pids = findPIDs(onPort: candidate)
            if pids.isEmpty { return candidate }
            candidate += 1
        }
        return port + 1
    }

    /// 해당 포트의 충돌 정보를 수집한다.
    static func detectConflict(onPort port: Int) -> PortConflictInfo? {
        let pids = findPIDs(onPort: port)
        guard !pids.isEmpty else { return nil }

        // 전체 명령어 수집 (중복 제거)
        var commands: [String] = []
        for pid in pids {
            let cmd = processCommand(pid: pid)
            if !cmd.isEmpty && !commands.contains(cmd) {
                commands.append(cmd)
            }
        }

        let suggested = findAvailablePort(startingFrom: port)
        return PortConflictInfo(port: port, pids: pids, processCommands: commands, suggestedPort: suggested)
    }

    /// 포트 충돌을 감지하고 portConflict를 설정한다.
    /// start() 실패 후 호출.
    func detectAndSetPortConflict(port: Int) async {
        let conflict = await Task.detached(priority: .userInitiated) {
            APIServer.detectConflict(onPort: port)
        }.value
        await MainActor.run {
            self.portConflict = conflict
        }
    }

    /// 충돌 중인 프로세스를 강제 종료한다.
    func killConflictingProcesses() {
        guard let conflict = portConflict else { return }
        for pid in conflict.pids {
            kill(pid, SIGKILL)
        }
        portConflict = nil
    }

    /// 포트 충돌 해결 후 서버를 재시작한다.
    func retryStart(config: AppConfig) {
        Task {
            // 재시작 전 에러 상태 초기화
            await MainActor.run {
                self.portConflict = nil
                self.setServerError(nil)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            do {
                try await self.start(config: config)
            } catch {
                let errorDesc = String(describing: error)
                let isPortConflict = errorDesc.contains("NIOCore.IOError") || errorDesc.contains("address already in use")
                if isPortConflict {
                    await self.detectAndSetPortConflict(port: config.apiPort)
                }
                await MainActor.run {
                    self.setServerError(error.localizedDescription)
                }
            }
        }
    }

    // MARK: - HTTP Routes

    private func registerRoutes(on router: RoutesBuilder) {

        // GET / — 서버 상태
        router.get { req -> [String: String] in
            return [
                "app": "Consolent",
                "version": "0.1.0",
                "status": "ok"
            ]
        }

        // ── Sessions ──

        // POST /sessions — 세션 생성
        router.post("sessions") { [self] req -> Response in
            let body = try req.content.decode(CreateSessionRequest.self)

            let cliType: CLIType
            if let typeStr = body.cliType, let parsed = CLIType(rawValue: typeStr) {
                cliType = parsed
            } else {
                cliType = AppConfig.shared.defaultCliType
            }

            let config = Session.Config(
                name: body.name,
                workingDirectory: body.workingDirectory ?? AppConfig.shared.cwd(for: cliType),
                shell: body.shell ?? AppConfig.shared.defaultShell,
                cliType: cliType,
                cliArgs: body.cliArgs ?? body.claudeArgs ?? [],
                autoApprove: body.autoApprove ?? false,
                idleTimeout: body.idleTimeout ?? AppConfig.shared.sessionIdleTimeout,
                env: body.env,
                channelEnabled: (cliType == .claudeCode) ? (body.channelEnabled ?? false) : false,
                channelPort: body.channelPort ?? 8787,
                channelServerName: body.channelServerName ?? "openai-compat",
                sdkEnabled: body.sdkEnabled ?? false,
                sdkPort: body.sdkPort ?? 8788,
                sdkModel: body.sdkModel,
                sdkPermissionMode: body.sdkPermissionMode ?? "acceptEdits"
            )

            let session = try await sessionManager.createSession(config: config)

            let appCfg = AppConfig.shared
            let bindHost = appCfg.apiBind == "0.0.0.0" ? "127.0.0.1" : appCfg.apiBind
            let localUrl = "http://\(bindHost):\(appCfg.apiPort)"

            let response = CreateSessionResponse(
                sessionId: session.id,
                name: session.name,
                status: session.status,
                createdAt: session.createdAt,
                localUrl: localUrl,
                tunnelUrl: session.tunnelURL,  // 터널 준비 전이면 nil; GET /sessions/:id 로 재조회 가능
                channelEnabled: session.isChannelMode,
                channelUrl: session.channelServerURL,
                sdkEnabled: session.isSDKMode,
                sdkUrl: session.sdkServerURL
            )

            return try await response.encodeResponse(status: .created, for: req)
        }

        // GET /sessions — 세션 목록
        router.get("sessions") { [self] req -> [String: [SessionInfo]] in
            return ["sessions": sessionManager.listSessions()]
        }

        // GET /sessions/:id — 세션 상태
        router.get("sessions", ":id") { [self] req -> SessionStatusResponse in
            guard let id = req.parameters.get("id"),
                  let session = sessionManager.getSession(id: id) else {
                throw Abort(.notFound, reason: "Session not found")
            }

            let statusAppCfg = AppConfig.shared
            let statusBindHost = statusAppCfg.apiBind == "0.0.0.0" ? "127.0.0.1" : statusAppCfg.apiBind

            return SessionStatusResponse(
                id: session.id,
                name: session.name,
                status: session.status,
                workingDirectory: session.config.workingDirectory,
                pendingApproval: session.pendingApproval.map {
                    ApprovalInfo(id: $0.id, prompt: $0.prompt, detectedAt: $0.detectedAt)
                },
                stats: SessionStats(
                    messagesSent: session.messageCount,
                    uptimeSeconds: Int(Date().timeIntervalSince(session.createdAt))
                ),
                localUrl: "http://\(statusBindHost):\(statusAppCfg.apiPort)",
                tunnelUrl: session.tunnelURL,
                channelEnabled: session.isChannelMode,
                channelUrl: session.channelServerURL,
                sdkEnabled: session.isSDKMode,
                sdkUrl: session.sdkServerURL,
                bridgeEnabled: session.isBridgeMode,
                bridgeUrl: session.bridgeServerURL
            )
        }

        // DELETE /sessions/:id — 세션 종료
        router.delete("sessions", ":id") { [self] req -> HTTPStatus in
            guard let id = req.parameters.get("id"),
                  sessionManager.getSession(id: id) != nil else {
                throw Abort(.notFound, reason: "Session not found")
            }
            await MainActor.run {
                sessionManager.deleteSession(id: id)
            }
            return .noContent
        }

        // PATCH /sessions/:id — 세션 이름 변경
        router.patch("sessions", ":id") { [self] req -> SessionStatusResponse in
            guard let id = req.parameters.get("id"),
                  let session = sessionManager.getSession(id: id) else {
                throw Abort(.notFound, reason: "Session not found")
            }

            let body = try req.content.decode(UpdateSessionRequest.self)

            if let newName = body.name {
                do {
                    try sessionManager.renameSession(id: id, newName: newName)
                } catch let error as ManagerError {
                    switch error {
                    case .nameAlreadyTaken:
                        throw Abort(.conflict, reason: error.localizedDescription)
                    case .invalidName:
                        throw Abort(.badRequest, reason: error.localizedDescription)
                    default:
                        throw Abort(.internalServerError, reason: error.localizedDescription)
                    }
                }
            }

            let statusAppCfg = AppConfig.shared
            let statusBindHost = statusAppCfg.apiBind == "0.0.0.0" ? "127.0.0.1" : statusAppCfg.apiBind

            return SessionStatusResponse(
                id: session.id,
                name: session.name,
                status: session.status,
                workingDirectory: session.config.workingDirectory,
                pendingApproval: session.pendingApproval.map {
                    ApprovalInfo(id: $0.id, prompt: $0.prompt, detectedAt: $0.detectedAt)
                },
                stats: SessionStats(
                    messagesSent: session.messageCount,
                    uptimeSeconds: Int(Date().timeIntervalSince(session.createdAt))
                ),
                localUrl: "http://\(statusBindHost):\(statusAppCfg.apiPort)",
                tunnelUrl: session.tunnelURL,
                channelEnabled: session.isChannelMode,
                channelUrl: session.channelServerURL,
                sdkEnabled: session.isSDKMode,
                sdkUrl: session.sdkServerURL,
                bridgeEnabled: session.isBridgeMode,
                bridgeUrl: session.bridgeServerURL
            )
        }

        // ── Messages ──

        // POST /sessions/:id/message — 메시지 전송 (동기)
        router.post("sessions", ":id", "message") { [self] req -> Session.MessageResponse in
            guard let id = req.parameters.get("id"),
                  let session = sessionManager.getSession(id: id) else {
                throw Abort(.notFound, reason: "Session not found")
            }

            let body = try req.content.decode(SendMessageRequest.self)
            let timeout = TimeInterval(body.timeout ?? 300)

            return try await session.sendMessage(text: body.text, timeout: timeout)
        }

        // ── Raw Input ──

        // POST /sessions/:id/input — Raw 입력 주입
        router.post("sessions", ":id", "input") { [self] req -> [String: Bool] in
            guard let id = req.parameters.get("id"),
                  let session = sessionManager.getSession(id: id) else {
                throw Abort(.notFound, reason: "Session not found")
            }

            let body = try req.content.decode(RawInputRequest.self)

            if let text = body.text {
                try session.injectInput(text: text)
            } else if let keys = body.keys {
                for key in keys {
                    if let data = keyToBytes(key) {
                        try session.injectInput(data: data)
                    }
                }
            }

            return ["ok": true]
        }

        // ── Output ──

        // GET /sessions/:id/output — 출력 버퍼 조회
        router.get("sessions", ":id", "output") { [self] req -> OutputResponse in
            guard let id = req.parameters.get("id"),
                  let session = sessionManager.getSession(id: id) else {
                throw Abort(.notFound, reason: "Session not found")
            }

            let raw = String(data: session.outputBuffer, encoding: .utf8) ?? ""
            let text = OutputParser.stripANSI(raw)

            return OutputResponse(
                text: text,
                raw: raw,
                offset: session.outputBuffer.count,
                totalBytes: session.outputBuffer.count
            )
        }

        // ── Approval ──

        // GET /sessions/:id/pending — 대기 중인 승인 요청
        router.get("sessions", ":id", "pending") { [self] req -> PendingApprovalResponse in
            guard let id = req.parameters.get("id"),
                  let session = sessionManager.getSession(id: id) else {
                throw Abort(.notFound, reason: "Session not found")
            }

            let info = session.pendingApproval.map {
                ApprovalInfo(id: $0.id, prompt: $0.prompt, detectedAt: $0.detectedAt)
            }
            return PendingApprovalResponse(pending: info)
        }

        // POST /sessions/:id/approve/:approvalId — 승인 응답
        router.post("sessions", ":id", "approve", ":approvalId") { [self] req -> [String: Bool] in
            guard let id = req.parameters.get("id"),
                  let approvalId = req.parameters.get("approvalId"),
                  let session = sessionManager.getSession(id: id) else {
                throw Abort(.notFound, reason: "Session not found")
            }

            let body = try req.content.decode(ApprovalResponse.self)
            try session.respondToApproval(id: approvalId, approved: body.approved)

            return ["ok": true]
        }
    }

    // MARK: - OpenAI Compatible API

    /// 기본 세션 ID. OpenAI 호환 API에서 세션을 자동 관리할 때 사용.
    private var defaultSessionId: String?

    private func registerOpenAIRoutes(on router: RoutesBuilder) {

        // GET /v1/models — 모델 목록 (활성 세션 이름 기반)
        // 활성 세션이 있으면 세션 이름을 모델로 반환, 없으면 CLIType 목록 (기존 호환성).
        router.get("v1", "models") { [self] req -> OpenAIModelsResponse in
            let activeSessions = sessionManager.listSessions()
                .filter { $0.status != .terminated }

            if !activeSessions.isEmpty {
                let models = activeSessions.map { info in
                    OpenAIModel(
                        id: info.name,
                        object: "model",
                        created: Int(info.createdAt.timeIntervalSince1970),
                        ownedBy: info.channelEnabled ? "channel" : "consolent"
                    )
                }
                return OpenAIModelsResponse(object: "list", data: models)
            }

            // 세션이 없으면 지원하는 CLI 유형 표시 (기존 동작)
            let models = CLIType.allCases.map { cliType in
                let adapter = cliType.createAdapter()
                return OpenAIModel(
                    id: adapter.modelId,
                    object: "model",
                    created: Int(Date().timeIntervalSince1970),
                    ownedBy: "consolent"
                )
            }
            return OpenAIModelsResponse(object: "list", data: models)
        }

        // POST /v1/chat/completions — 채팅 완성 (OpenAI 호환)
        router.post("v1", "chat", "completions") { [self] req -> Response in
            print("[API] /v1/chat/completions 요청 수신")
            let body = try req.content.decode(OpenAIChatRequest.self)
            print("[API] stream=\(body.stream ?? false), model=\(body.model ?? "default"), messages=\(body.messages.count)개")

            // 마지막 user 메시지 추출
            guard let lastUserMsg = body.messages.last(where: { $0.role == "user" }) else {
                throw Abort(.badRequest, reason: "No user message found")
            }

            // 시스템 프롬프트 추출 (클라이언트가 형식/역할을 지정하는 핵심 컨텍스트)
            let systemPrompt = body.messages
                .filter { $0.role == "system" }
                .map { $0.textContent }
                .joined(separator: "\n")

            // 이미지 content → 임시 파일 저장 → 경로를 메시지에 포함
            // CLI 도구들은 파일 경로를 드래그 앤 드롭처럼 처리한다.
            var imagePaths: [String] = []
            if let content = lastUserMsg.content {
                for imageURL in content.imageURLs {
                    if let path = saveImageToTempFile(imageURL) {
                        imagePaths.append(path)
                    }
                }
            }

            let textContent = lastUserMsg.textContent
            guard !textContent.isEmpty || !imagePaths.isEmpty else {
                throw Abort(.badRequest, reason: "No user message found")
            }

            // 세션 해결 (먼저 수행 — CLI 타입별 시스템 프롬프트 제한에 필요)
            // proxyBridgeRequests=true이면 Agent/브릿지 세션도 세션 객체를 반환받아 프록시 처리
            let session = try await resolveSession(model: body.model)

            // Agent/브릿지 모드 세션 → 브릿지 서버로 투명 프록시
            // resolveSession()에서 이미 proxy=true일 때만 이 세션이 반환됨
            if session.isBridgeMode, let bridgeUrl = session.bridgeServerURL {
                print("[API] 🔀 프록시 → \(bridgeUrl)/v1/chat/completions (stream=\(body.stream ?? false))")
                return try await proxyToBridge(req: req, bridgeBaseURL: bridgeUrl, streaming: body.stream ?? false)
            }

            // 시스템 프롬프트 + 이미지 경로 + 텍스트 결합
            // PTY에서 \n은 Enter(전송)로 해석되므로 공백으로 결합해야 한다.
            // 시스템 프롬프트 내부의 줄바꿈도 공백으로 치환.
            var parts: [String] = []
            if !systemPrompt.isEmpty {
                // CLI 타입별 시스템 프롬프트 크기 제한
                // Gemini 등 TUI가 긴 입력을 처리하지 못하는 CLI는 제한 적용
                let maxPromptLength = systemPromptLimit(for: session.config.cliType)
                var flatPrompt = systemPrompt.replacingOccurrences(of: "\n", with: " ")
                if flatPrompt.count > maxPromptLength {
                    flatPrompt = String(flatPrompt.prefix(maxPromptLength))
                    print("[API] ✂️ 시스템 프롬프트 축소: \(systemPrompt.count)자 → \(maxPromptLength)자 (\(session.config.cliType))")
                }
                parts.append(flatPrompt)
                print("[API] 📋 시스템 프롬프트: \(systemPrompt.prefix(80))...")
            }
            if !imagePaths.isEmpty {
                parts.append(imagePaths.joined(separator: " "))
                print("[API] 📷 이미지 \(imagePaths.count)개 첨부")
            }
            if !textContent.isEmpty {
                let flatText = textContent.replacingOccurrences(of: "\n", with: " ")
                parts.append(flatText)
            }
            let lastUserMessage = parts.joined(separator: " ")
            print("[API] 메시지: \(lastUserMessage.prefix(80))")
            let timeout = TimeInterval(body.timeout ?? 300)
            print("[API] 세션: \(session.id), status=\(session.status.rawValue)")

            // 디버그 로깅: API 요청
            DebugLogger.shared.logAPIRequest(
                sessionId: session.id, method: "POST", path: "/v1/chat/completions",
                model: body.model, message: lastUserMessage, streaming: body.stream ?? false
            )

            // stream + json_object: 비스트리밍으로 전체 응답 수집 → JSON 추출 → SSE 형식 반환
            // 스트리밍 델타 수집은 완료 감지가 불안정 (이미지 처리 등 긴 작업에서 조기 종료)
            // sendMessage는 timeout까지 안정적으로 대기하므로 JSON 추출에 더 적합
            if body.stream == true && body.expectsJSON {
                print("[API] ▶ JSON 모드 (sendMessage → JSON 추출 → SSE)")
                let completionId = "chatcmpl-\(UUID().uuidString.prefix(8).lowercased())"
                let created = Int(Date().timeIntervalSince1970)
                let modelId = session.name
                let sseEncoder = JSONEncoder()
                sseEncoder.keyEncodingStrategy = .convertToSnakeCase

                // 비스트리밍으로 전체 응답 수집
                let result = try await session.sendMessage(text: lastUserMessage, timeout: timeout)
                var responseText = sanitizeForJSON(result.response.result)

                // JSON 추출
                if let json = extractJSON(from: responseText) {
                    print("[API] 📋 JSON 추출: \(responseText.count)자 → \(json.count)자")
                    responseText = json
                } else {
                    print("[API] ⚠️ JSON 추출 실패, 원본 \(responseText.count)자")
                    responseText = buildJSONExtractionError(rawResponse: responseText)
                }

                // SSE 형식으로 반환: role → content(전체) → finish → [DONE]
                let response = Response(
                    status: .ok,
                    headers: [
                        "Content-Type": "text/event-stream",
                        "Cache-Control": "no-cache",
                        "Connection": "keep-alive",
                        "X-Accel-Buffering": "no",
                    ]
                )

                let finalResponseText = responseText
                response.body = .init(managedAsyncStream: { writer in
                    for chunk in [
                        OpenAIStreamChunk(id: completionId, object: "chat.completion.chunk",
                            created: created, model: modelId,
                            choices: [OpenAIStreamChoice(index: 0,
                                delta: OpenAIStreamDelta(role: "assistant", content: nil),
                                finishReason: nil)]),
                        OpenAIStreamChunk(id: completionId, object: "chat.completion.chunk",
                            created: created, model: modelId,
                            choices: [OpenAIStreamChoice(index: 0,
                                delta: OpenAIStreamDelta(role: nil, content: finalResponseText),
                                finishReason: nil)]),
                        OpenAIStreamChunk(id: completionId, object: "chat.completion.chunk",
                            created: created, model: modelId,
                            choices: [OpenAIStreamChoice(index: 0,
                                delta: OpenAIStreamDelta(role: nil, content: nil),
                                finishReason: "stop")])
                    ] {
                        if let d = try? sseEncoder.encode(chunk),
                           let s = String(data: d, encoding: .utf8) {
                            var buf = ByteBufferAllocator().buffer(capacity: s.utf8.count + 20)
                            buf.writeString("data: \(s)\n\n")
                            try await writer.writeBuffer(buf)
                        }
                    }
                    var doneBuf = ByteBufferAllocator().buffer(capacity: 20)
                    doneBuf.writeString("data: [DONE]\n\n")
                    try await writer.writeBuffer(doneBuf)
                })

                return response
            }

            // stream 모드: 실시간 SSE (Server-Sent Events)
            if body.stream == true {
                print("[API] ▶ 스트리밍 모드 진입")
                let completionId = "chatcmpl-\(UUID().uuidString.prefix(8).lowercased())"
                let created = Int(Date().timeIntervalSince1970)
                let modelId = session.name
                let sseEncoder = JSONEncoder()
                sseEncoder.keyEncodingStrategy = .convertToSnakeCase

                let eventStream = session.sendMessageStreaming(
                    text: lastUserMessage,
                    timeout: timeout
                )

                let response = Response(
                    status: .ok,
                    headers: [
                        "Content-Type": "text/event-stream",
                        "Cache-Control": "no-cache",
                        "Connection": "keep-alive",
                        "X-Accel-Buffering": "no",
                    ]
                )

                response.body = .init(managedAsyncStream: { writer in
                    // 1. role chunk 전송
                    let roleChunk = OpenAIStreamChunk(
                        id: completionId, object: "chat.completion.chunk",
                        created: created, model: modelId,
                        choices: [OpenAIStreamChoice(
                            index: 0,
                            delta: OpenAIStreamDelta(role: "assistant", content: nil),
                            finishReason: nil
                        )]
                    )
                    if let d = try? sseEncoder.encode(roleChunk),
                       let s = String(data: d, encoding: .utf8) {
                        var buf = ByteBufferAllocator().buffer(capacity: s.utf8.count + 20)
                        buf.writeString("data: \(s)\n\n")
                        try await writer.writeBuffer(buf)
                    }

                    // 2. content delta 스트리밍
                    for await event in eventStream {
                        switch event {
                        case .delta(let text):
                            let sanitized = sanitizeForJSON(text)
                            let contentChunk = OpenAIStreamChunk(
                                id: completionId, object: "chat.completion.chunk",
                                created: created, model: modelId,
                                choices: [OpenAIStreamChoice(
                                    index: 0,
                                    delta: OpenAIStreamDelta(role: nil, content: sanitized),
                                    finishReason: nil
                                )]
                            )
                            if let d = try? sseEncoder.encode(contentChunk),
                               let s = String(data: d, encoding: .utf8) {
                                var buf = ByteBufferAllocator().buffer(capacity: s.utf8.count + 20)
                                buf.writeString("data: \(s)\n\n")
                                try await writer.writeBuffer(buf)
                            }

                        case .done:
                            // finish chunk
                            let finishChunk = OpenAIStreamChunk(
                                id: completionId, object: "chat.completion.chunk",
                                created: created, model: modelId,
                                choices: [OpenAIStreamChoice(
                                    index: 0,
                                    delta: OpenAIStreamDelta(role: nil, content: nil),
                                    finishReason: "stop"
                                )]
                            )
                            if let d = try? sseEncoder.encode(finishChunk),
                               let s = String(data: d, encoding: .utf8) {
                                var buf = ByteBufferAllocator().buffer(capacity: s.utf8.count + 20)
                                buf.writeString("data: \(s)\n\n")
                                try await writer.writeBuffer(buf)
                            }
                            // [DONE] 마커
                            var doneBuf = ByteBufferAllocator().buffer(capacity: 20)
                            doneBuf.writeString("data: [DONE]\n\n")
                            try await writer.writeBuffer(doneBuf)

                        case .error(let msg):
                            // 에러를 content chunk로 전송 후 종료
                            let errChunk = OpenAIStreamChunk(
                                id: completionId, object: "chat.completion.chunk",
                                created: created, model: modelId,
                                choices: [OpenAIStreamChoice(
                                    index: 0,
                                    delta: OpenAIStreamDelta(role: nil, content: "[Error: \(msg)]"),
                                    finishReason: "stop"
                                )]
                            )
                            if let d = try? sseEncoder.encode(errChunk),
                               let s = String(data: d, encoding: .utf8) {
                                var buf = ByteBufferAllocator().buffer(capacity: s.utf8.count + 20)
                                buf.writeString("data: \(s)\n\n")
                                try await writer.writeBuffer(buf)
                            }
                            var doneBuf = ByteBufferAllocator().buffer(capacity: 20)
                            doneBuf.writeString("data: [DONE]\n\n")
                            try await writer.writeBuffer(doneBuf)
                        }
                    }
                })

                return response
            }

            // 비-stream 모드: 일반 JSON
            let result = try await session.sendMessage(text: lastUserMessage, timeout: timeout)

            let completionId = "chatcmpl-\(result.messageId)"
            let created = Int(Date().timeIntervalSince1970)
            let modelId = session.name
            var responseText = sanitizeForJSON(result.response.result)

            // response_format: json_object → 응답에서 JSON 블록만 추출
            // 클라이언트가 명시적으로 JSON을 요청한 경우에만 동작
            if body.expectsJSON {
                if let json = extractJSON(from: responseText) {
                    print("[API] 📋 JSON 추출: \(responseText.count)자 → \(json.count)자")
                    responseText = json
                } else {
                    print("[API] ⚠️ JSON 추출 실패, 원본 \(responseText.count)자")
                    responseText = buildJSONExtractionError(rawResponse: responseText)
                }
            }

            let openAIResponse = OpenAIChatResponse(
                id: completionId,
                object: "chat.completion",
                created: created,
                model: modelId,
                choices: [
                    OpenAIChoice(
                        index: 0,
                        message: OpenAIChatMessage(role: "assistant", content: .string(responseText)),
                        finishReason: "stop"
                    )
                ],
                usage: OpenAIUsage(promptTokens: 0, completionTokens: 0, totalTokens: 0)
            )

            // 디버그 로깅: API 응답 (비스트리밍)
            DebugLogger.shared.logAPIResponse(
                sessionId: session.id, path: "/v1/chat/completions",
                statusCode: 200, responseText: responseText,
                durationMs: result.response.durationMs
            )

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(openAIResponse)

            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }
    }

    // MARK: - Bridge Proxy

    /// Agent/브릿지 서버로 요청을 투명하게 포워딩한다.
    /// 스트리밍: URLSession.bytes()로 SSE 라인을 읽어 Vapor response에 그대로 전달.
    /// 비스트리밍: URLSession.data()로 JSON 응답을 받아 그대로 반환.
    private func proxyToBridge(req: Request, bridgeBaseURL: String, streaming: Bool) async throws -> Response {
        guard let url = URL(string: "\(bridgeBaseURL)/v1/chat/completions") else {
            throw Abort(.internalServerError, reason: "Invalid bridge URL: \(bridgeBaseURL)")
        }

        // 원본 요청 body를 그대로 사용
        guard let bodyData = req.body.data.map({ Data($0.readableBytesView) }) else {
            throw Abort(.badRequest, reason: "Empty request body")
        }

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "POST"
        urlReq.httpBody = bodyData
        urlReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 브릿지 서버 인증: Consolent API 키를 그대로 전달 (브릿지 서버가 동일 키로 검증)
        if let auth = req.headers["Authorization"].first {
            urlReq.setValue(auth, forHTTPHeaderField: "Authorization")
        }
        urlReq.timeoutInterval = 600

        if streaming {
            let streamingRequest = urlReq
            // SSE 스트리밍: 브릿지 서버의 이벤트 라인을 클라이언트에 그대로 전달
            let response = Response(
                status: .ok,
                headers: [
                    "Content-Type": "text/event-stream",
                    "Cache-Control": "no-cache",
                    "Connection": "keep-alive",
                    "X-Accel-Buffering": "no",
                    "X-Bridge-Url": bridgeBaseURL,  // 직접 연결용 힌트
                ]
            )

            response.body = .init(managedAsyncStream: { writer in
                let (asyncBytes, _) = try await URLSession.shared.bytes(for: streamingRequest)
                for try await line in asyncBytes.lines {
                    // "data: ..." 라인을 그대로 포워딩
                    var buf = ByteBufferAllocator().buffer(capacity: line.utf8.count + 2)
                    buf.writeString("\(line)\n\n")
                    try await writer.writeBuffer(buf)

                    if line == "data: [DONE]" { break }
                }
            })
            return response

        } else {
            // 비스트리밍: JSON 응답 그대로 반환
            let (data, urlResponse) = try await URLSession.shared.data(for: urlReq)
            let statusCode = (urlResponse as? HTTPURLResponse)?.statusCode ?? 200
            return Response(
                status: HTTPResponseStatus(statusCode: statusCode),
                headers: [
                    "Content-Type": "application/json",
                    "X-Bridge-Url": bridgeBaseURL,
                ],
                body: .init(data: data)
            )
        }
    }

    /// OpenAI 호환 API용 세션 해결.
    /// model 필드가 있으면 세션 이름으로 매칭, 없으면 기존 폴백 로직 사용.
    /// 채널 모드 세션은 항상 410 Gone (자체 MCP 서버가 직접 처리).
    /// Agent/브릿지 모드 세션:
    ///   - proxyBridgeRequests=false(기본): 410 Gone + 브릿지 URL 안내
    ///   - proxyBridgeRequests=true: 세션 반환 → 호출자에서 프록시 처리
    private func resolveSession(model: String?) async throws -> Session {
        let proxy = AppConfig.shared.proxyBridgeRequests

        // model 필드로 세션 이름 매칭
        if let model = model, !model.isEmpty {
            if let session = sessionManager.getSession(name: model) {
                // 채널 모드는 항상 410 — MCP 서버가 자체적으로 처리
                if session.isChannelMode {
                    let channelUrl = session.channelServerURL ?? "http://localhost:\(session.config.channelPort)"
                    throw Abort(.gone, reason: "Session '\(model)' is in channel mode. Send requests directly to \(channelUrl)/v1")
                }
                // Agent 모드: 프록시 모드이면 세션 반환, 아니면 410
                if session.isSDKMode {
                    if proxy {
                        print("[API] 🔀 Agent 세션 '\(model)' → 프록시 모드")
                        return session
                    }
                    let sdkUrl = session.sdkServerURL ?? "http://localhost:\(session.config.sdkPort)"
                    throw Abort(.gone, reason: "Session '\(model)' is in Agent mode. Send requests directly to \(sdkUrl)/v1")
                }
                // 브릿지 모드: 프록시 모드이면 세션 반환, 아니면 410
                if session.isBridgeMode {
                    if proxy {
                        print("[API] 🔀 브릿지 세션 '\(model)' → 프록시 모드")
                        return session
                    }
                    let bridgeUrl = session.bridgeServerURL ?? "unknown"
                    throw Abort(.gone, reason: "Session '\(model)' is in bridge mode. Send requests directly to \(bridgeUrl)/v1")
                }
                guard session.status == .ready else {
                    throw Abort(.conflict, reason: "Session '\(model)' exists but is not ready (status: \(session.status.rawValue))")
                }
                print("[API] 모델 '\(model)' → 세션 '\(session.id)' 매칭")
                return session
            }
            // 매칭 실패 → 기존 폴백 (하위 호환성)
            print("[API] ⚠️ 모델 '\(model)' 매칭 세션 없음, 기본 세션으로 폴백")
        }
        return try await getOrCreateDefaultSession()
    }

    /// 기본 세션 폴백.
    /// 우선순위: 고정된 세션 → 앱에서 선택된 세션 → 아무 ready 세션 → 에러
    /// 채널/SDK 모드 세션은 폴백 대상에서 제외 (자체 API 서버를 가지므로).
    private func getOrCreateDefaultSession() async throws -> Session {
        // 1. 이전에 고정된 세션이 ready + 비채널 + 비SDK이면 계속 사용 (대화 컨텍스트 유지)
        if let id = defaultSessionId, let session = sessionManager.getSession(id: id),
           session.status == .ready, !session.isChannelMode, !session.isSDKMode {
            return session
        }

        // 2. 앱에서 현재 선택된 세션이 ready + 비채널 + 비SDK이면 사용
        if let selected = sessionManager.selectedSession,
           selected.status == .ready, !selected.isChannelMode, !selected.isSDKMode {
            defaultSessionId = selected.id
            return selected
        }

        // 3. 아무 ready + 비채널 + 비SDK 세션이라도 사용
        let readySessions = sessionManager.listSessions().filter { $0.status == .ready && !$0.channelEnabled && !$0.sdkEnabled }
        if let first = readySessions.first,
           let session = sessionManager.getSession(id: first.id) {
            defaultSessionId = session.id
            return session
        }

        // 4. ready 세션이 없으면 에러
        throw Abort(.serviceUnavailable, reason: "No ready session available. Please create and initialize a session in the app first.")
    }

    // MARK: - WebSocket

    private func registerWebSocket(on app: Application, apiKey: String) {
        app.webSocket("sessions", ":id", "stream") { [self] req, ws async in
            // 토큰 검증 (query param)
            let token = req.query[String.self, at: "token"]
            guard token == apiKey else {
                try? await ws.close(code: .policyViolation)
                return
            }

            guard let id = req.parameters.get("id"),
                  let session = sessionManager.getSession(id: id) else {
                try? await ws.send(#"{"type":"error","message":"Session not found"}"#)
                try? await ws.close(code: .normalClosure)
                return
            }

            // 출력 스트리밍
            let previousCallback = session.onTerminalOutput
            session.onTerminalOutput = { data in
                previousCallback?(data)
                if let text = String(data: data, encoding: .utf8) {
                    let msg = StreamMessage(type: "output", text: text)
                    if let json = try? JSONEncoder().encode(msg),
                       let str = String(data: json, encoding: .utf8) {
                        ws.send(str)
                    }
                }
            }

            // 클라이언트 입력 수신
            ws.onText { ws, text in
                guard let data = text.data(using: .utf8),
                      let msg = try? JSONDecoder().decode(StreamInput.self, from: data) else { return }

                switch msg.type {
                case "input":
                    if let inputText = msg.text {
                        try? session.injectInput(text: inputText + "\n")
                    }
                case "approve":
                    if let approvalId = msg.id {
                        try? session.respondToApproval(id: approvalId, approved: msg.approved ?? true)
                    }
                default:
                    break
                }
            }

            // 연결 종료 시 콜백 복원
            ws.onClose.whenComplete { _ in
                session.onTerminalOutput = previousCallback
            }
        }
    }

    // MARK: - Helpers

    private func keyToBytes(_ key: String) -> Data? {
        switch key.lowercased() {
        case "ctrl+c": return Data([3])
        case "ctrl+d": return Data([4])
        case "ctrl+z": return Data([26])
        case "ctrl+l": return Data([12])
        case "enter", "return": return Data([10])
        case "tab": return Data([9])
        case "escape", "esc": return Data([27])
        case "up": return Data([27, 91, 65])
        case "down": return Data([27, 91, 66])
        case "right": return Data([27, 91, 67])
        case "left": return Data([27, 91, 68])
        default: return key.data(using: .utf8)
        }
    }
}

// MARK: - Vapor Content Extensions

// Content conformance for types defined in other files.
// These are Codable structs — Vapor's Content requires Codable + Sendable.
extension SessionInfo: @unchecked Sendable, Content {}
extension Session.MessageResponse: @unchecked Sendable, Content {}

// MARK: - Request/Response DTOs

struct CreateSessionRequest: Content {
    var name: String?            // 세션 이름 (model ID로 사용). nil이면 CLI 타입 이름 자동 부여.
    var workingDirectory: String?
    var shell: String?
    var cliType: String?
    var cliArgs: [String]?
    var claudeArgs: [String]?  // 하위 호환용
    var autoApprove: Bool?
    var idleTimeout: Int?
    var env: [String: String]?
    var channelEnabled: Bool?         // 채널 서버 모드 (Claude Code 전용)
    var channelPort: Int?             // 채널 서버 포트 (기본 8787)
    var channelServerName: String?    // MCP 서버 이름 (기본 "openai-compat")
    var sdkEnabled: Bool?             // SDK 모드 (Agent SDK 기반)
    var sdkPort: Int?                 // SDK 브릿지 서버 포트 (기본 8788)
    var sdkModel: String?             // SDK에서 사용할 모델
    var sdkPermissionMode: String?    // SDK 퍼미션 모드
}

struct CreateSessionResponse: Content {
    let sessionId: String
    let name: String             // 세션 이름 (= 클라이언트의 model 필드와 매칭)
    let status: Session.Status
    let createdAt: Date
    let localUrl: String
    let tunnelUrl: String?
    let channelEnabled: Bool
    let channelUrl: String?      // 채널 모드 활성 시 채널 서버 URL
    let sdkEnabled: Bool
    let sdkUrl: String?          // SDK 모드 활성 시 SDK 서버 URL
}

struct UpdateSessionRequest: Content {
    var name: String?
}

struct SessionStatusResponse: Content {
    let id: String
    let name: String             // 세션 이름
    let status: Session.Status
    let workingDirectory: String
    let pendingApproval: ApprovalInfo?
    let stats: SessionStats
    let localUrl: String
    let tunnelUrl: String?
    let channelEnabled: Bool
    let channelUrl: String?      // 채널 모드 활성 시 채널 서버 URL
    let sdkEnabled: Bool
    let sdkUrl: String?          // SDK 모드 활성 시 SDK 서버 URL
    let bridgeEnabled: Bool      // 모든 브릿지 모드 (SDK + Gemini Stream + Codex App Server)
    let bridgeUrl: String?       // 브릿지 서버 URL
}

struct SessionStats: Content {
    let messagesSent: Int
    let uptimeSeconds: Int
}

struct ApprovalInfo: Content {
    let id: String
    let prompt: String
    let detectedAt: Date
}

struct SendMessageRequest: Content {
    let text: String
    var timeout: Int?
}

struct RawInputRequest: Content {
    var text: String?
    var keys: [String]?
}

struct OutputResponse: Content {
    let text: String
    let raw: String
    let offset: Int
    let totalBytes: Int
}

struct PendingApprovalResponse: Content {
    let pending: ApprovalInfo?
}

struct ApprovalResponse: Content {
    let approved: Bool
}

struct StreamMessage: Codable {
    let type: String
    var text: String?
    var id: String?
    var prompt: String?
    var status: String?
}

struct StreamInput: Codable {
    let type: String
    var text: String?
    var id: String?
    var approved: Bool?
}

// MARK: - OpenAI Compatible DTOs

struct OpenAIChatRequest: Content {
    let messages: [OpenAIChatMessage]
    var model: String?
    var stream: Bool?
    var temperature: Double?
    var maxTokens: Int?
    var timeout: Int?
    var responseFormat: ResponseFormat?
    // OpenAI 호환 클라이언트가 보내는 추가 필드 (무시하되 디코딩 에러 방지)
    var topP: Double?
    var n: Int?
    var stop: AnyCodableValue?
    var presencePenalty: Double?
    var frequencyPenalty: Double?
    var user: String?

    /// response_format이 json_object인지 확인
    var expectsJSON: Bool {
        responseFormat?.type == "json_object"
    }
}

struct ResponseFormat: Codable {
    let type: String  // "text" 또는 "json_object"
}

/// OpenAI content는 문자열 또는 배열 형태 모두 가능.
/// "content": "hello"  또는  "content": [{"type":"text","text":"hello"}]
struct OpenAIChatMessage: Content {
    let role: String
    let content: MessageContent?

    /// 텍스트 추출 헬퍼
    var textContent: String {
        content?.text ?? ""
    }
}

/// 문자열 / 배열 양쪽 모두 디코딩 가능한 content 타입
enum MessageContent: Codable {
    case string(String)
    case parts([ContentPart])

    var text: String {
        switch self {
        case .string(let s): return s
        case .parts(let parts):
            return parts
                .filter { $0.type == "text" }
                .compactMap { $0.text }
                .joined(separator: "\n")
        }
    }

    /// content에서 이미지 URL(base64 data URL 또는 HTTP URL)을 추출한다.
    var imageURLs: [String] {
        switch self {
        case .string: return []
        case .parts(let parts):
            return parts
                .filter { $0.type == "image_url" }
                .compactMap { $0.imageUrl?.url }
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            self = .string(str)
        } else if let parts = try? container.decode([ContentPart].self) {
            self = .parts(parts)
        } else {
            self = .string("")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .parts(let p): try container.encode(p)
        }
    }
}

struct ContentPart: Codable {
    let type: String
    var text: String?
    var imageUrl: ImageURL?
}

struct ImageURL: Codable {
    let url: String
    var detail: String?
}

/// CLI 타입별 시스템 프롬프트 최대 길이 (자).
/// Gemini 등 TUI가 긴 단일 줄 입력을 렌더링하지 못하는 CLI는 제한을 적용한다.
private func systemPromptLimit(for cliType: CLIType) -> Int {
    switch cliType {
    case .gemini:
        return 2000    // Gemini TUI는 긴 입력에서 렌더링 과부하 발생
    case .claudeCode:
        return 8000    // Claude Code는 비교적 긴 입력 처리 가능
    case .codex:
        return 8000    // Codex도 비교적 긴 입력 처리 가능
    }
}

/// base64 data URL을 임시 파일로 저장하고 경로를 반환한다.
/// CLI 도구들은 터미널에서 파일 경로를 받아 이미지를 처리할 수 있다.
/// 형식: "data:image/jpeg;base64,/9j/4AAQ..." → /tmp/consolent_img_xxx.jpeg
private func saveImageToTempFile(_ dataURL: String) -> String? {
    // data URL 파싱: "data:{mimeType};base64,{data}"
    guard dataURL.hasPrefix("data:"),
          let semicolonIdx = dataURL.firstIndex(of: ";"),
          let commaIdx = dataURL.firstIndex(of: ",") else {
        // HTTP URL이면 그대로 반환 (CLI가 URL을 직접 처리할 수도 있음)
        if dataURL.hasPrefix("http://") || dataURL.hasPrefix("https://") {
            return dataURL
        }
        return nil
    }

    let mimeType = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: 5)..<semicolonIdx])
    let base64String = String(dataURL[dataURL.index(after: commaIdx)...])

    guard let imageData = Data(base64Encoded: base64String, options: .ignoreUnknownCharacters) else {
        print("[API] ⚠️ base64 디코딩 실패")
        return nil
    }

    // MIME → 확장자 매핑
    let ext: String
    switch mimeType {
    case "image/jpeg", "image/jpg": ext = "jpeg"
    case "image/png": ext = "png"
    case "image/gif": ext = "gif"
    case "image/webp": ext = "webp"
    case "image/svg+xml": ext = "svg"
    default: ext = "png"
    }

    let filename = "consolent_img_\(UUID().uuidString.prefix(8).lowercased()).\(ext)"
    let tempPath = NSTemporaryDirectory() + filename

    do {
        try imageData.write(to: URL(fileURLWithPath: tempPath))
        print("[API] 📷 이미지 저장: \(tempPath) (\(imageData.count / 1024)KB)")
        return tempPath
    } catch {
        print("[API] ⚠️ 이미지 파일 저장 실패: \(error)")
        return nil
    }
}

/// 텍스트에서 가장 큰 JSON 객체/배열 블록을 추출한다.
/// CLI 응답에 대화형 텍스트("I'll read the image...")와 JSON이 섞여 있을 때,
/// response_format: json_object를 요청한 클라이언트를 위해 JSON만 반환한다.
private func extractJSON(from text: String) -> String? {
    // 코드 펜스 안의 JSON 우선 탐색: ```json ... ``` 또는 ``` ... ```
    if let fenceRegex = try? NSRegularExpression(
        pattern: "```(?:json)?\\s*\\n?(.+?)\\n?```",
        options: [.dotMatchesLineSeparators]
    ) {
        let range = NSRange(text.startIndex..., in: text)
        if let match = fenceRegex.firstMatch(in: text, options: [], range: range),
           let jsonRange = Range(match.range(at: 1), in: text) {
            let candidate = String(text[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isValidJSON(candidate) {
                return candidate
            }
            // LaTeX 백슬래시 등 수정 후 재시도
            let fixed = repairJSON(candidate)
            if fixed != candidate && isValidJSON(fixed) {
                print("[API] 🔧 JSON 수정 적용 (백슬래시/줄바꿈 등)")
                return fixed
            }
        }
    }

    // 브레이스 매칭: 가장 긴 { ... } 또는 [ ... ] 블록
    for opener: Character in ["{", "["] {
        let closer: Character = opener == "{" ? "}" : "]"
        if let startIdx = text.firstIndex(of: opener) {
            var depth = 0
            var inString = false
            var escape = false
            var bestEnd: String.Index?

            for idx in text.indices[startIdx...] {
                let ch = text[idx]

                if escape { escape = false; continue }
                if ch == "\\" && inString { escape = true; continue }
                if ch == "\"" { inString = !inString; continue }
                if inString { continue }

                if ch == opener { depth += 1 }
                else if ch == closer {
                    depth -= 1
                    if depth == 0 {
                        bestEnd = text.index(after: idx)
                        break
                    }
                }
            }

            if let endIdx = bestEnd {
                let candidate = String(text[startIdx..<endIdx])
                if isValidJSON(candidate) {
                    return candidate
                }
                // LaTeX 백슬래시 등 수정 후 재시도
                let fixed = repairJSON(candidate)
                if fixed != candidate && isValidJSON(fixed) {
                    print("[API] 🔧 JSON 수정 적용 (백슬래시/줄바꿈 등)")
                    return fixed
                }
            }
        }
    }

    return nil
}

/// JSON 유효성 검사. 실패 시 백슬래시 수정 후 재시도.
/// LLM이 LaTeX(`\frac`, `\;`) 등을 JSON 이스케이프 없이 반환하는 경우가 잦다.
/// `\f` → form feed, `\;` → invalid escape 등으로 JSON.parse가 실패하므로
/// 유효하지 않은 백슬래시 시퀀스를 `\\`로 이스케이프하여 복구한다.
private func isValidJSON(_ text: String) -> Bool {
    guard let data = text.data(using: .utf8) else { return false }
    return (try? JSONSerialization.jsonObject(with: data)) != nil
}

/// LLM이 생성한 JSON의 흔한 오류를 수정한다.
/// 1. 문자열 내 잘못된 백슬래시: \frac, \; → \\frac, \\; (LaTeX 등)
/// 2. 문자열 내 실제 줄바꿈/탭/제어문자 → \n, \t 등으로 이스케이프
/// JSON 유효 이스케이프: \", \\, \/, \b, \f, \n, \r, \t, \uXXXX
private func repairJSON(_ text: String) -> String {
    var result = ""
    var inString = false
    var i = text.startIndex

    while i < text.endIndex {
        let ch = text[i]

        // 따옴표 토글 (이스케이프된 \" 제외)
        if ch == "\"" {
            // 직전 문자가 홀수 개의 \ 인지 확인
            var backslashCount = 0
            var checkIdx = result.endIndex
            while checkIdx > result.startIndex {
                checkIdx = result.index(before: checkIdx)
                if result[checkIdx] == "\\" { backslashCount += 1 } else { break }
            }
            if backslashCount % 2 == 0 {
                inString = !inString
            }
            result.append(ch)
            i = text.index(after: i)
            continue
        }

        // 문자열 내부 처리
        if inString {
            // 실제 줄바꿈/탭/제어문자 → JSON 이스케이프
            if ch == "\n" { result += "\\n"; i = text.index(after: i); continue }
            if ch == "\r" { result += "\\r"; i = text.index(after: i); continue }
            if ch == "\t" { result += "\\t"; i = text.index(after: i); continue }
            if ch.asciiValue != nil && ch.asciiValue! < 0x20 {
                // 기타 제어 문자 → \uXXXX
                result += String(format: "\\u%04x", ch.asciiValue!)
                i = text.index(after: i)
                continue
            }

            // 백슬래시 이스케이프 검사
            if ch == "\\" {
                let nextIdx = text.index(after: i)
                if nextIdx < text.endIndex {
                    let next = text[nextIdx]
                    // JSON 유효 이스케이프 → 그대로
                    if "\"\\bfnrt/".contains(next) {
                        result.append(ch)
                        result.append(next)
                        i = text.index(after: nextIdx)
                        continue
                    }
                    // \uXXXX → 그대로
                    if next == "u" {
                        let hexStart = text.index(after: nextIdx)
                        if let hexEnd = text.index(hexStart, offsetBy: 4, limitedBy: text.endIndex) {
                            let hex = text[hexStart..<hexEnd]
                            if hex.allSatisfy({ $0.isHexDigit }) {
                                result.append(contentsOf: text[i..<hexEnd])
                                i = hexEnd
                                continue
                            }
                        }
                    }
                    // 유효하지 않은 이스케이프 → \\ 로 변환 (LaTeX 등)
                    result += "\\\\"
                    i = nextIdx
                    continue
                }
            }
        }

        result.append(ch)
        i = text.index(after: i)
    }

    return result
}

/// JSON 추출 실패 시 에러 응답을 JSON으로 안전하게 생성한다.
/// JSONSerialization으로 인코딩하여 이스케이프 누락 방지.
private func buildJSONExtractionError(rawResponse: String) -> String {
    let errorDict: [String: Any] = [
        "error": "JSON extraction failed",
        "raw_response": rawResponse
    ]
    if let data = try? JSONSerialization.data(withJSONObject: errorDict, options: [.sortedKeys]),
       let json = String(data: data, encoding: .utf8) {
        return json
    }
    // JSONSerialization마저 실패하면 최소한의 에러만 반환
    return "{\"error\":\"JSON extraction failed\"}"
}

/// 터미널 출력에서 JSON 비호환 제어 문자를 제거한다.
/// SwiftTerm의 translateToString()이 반환하는 텍스트에 ESC(\x1B), NUL(\x00) 등
/// 잔여 제어 문자가 남아있을 수 있으며, JSONEncoder는 이를 \uXXXX로 이스케이프하지만
/// 일부 클라이언트(JavaScript JSON.parse 등)가 이를 처리하지 못하는 경우가 있다.
private func sanitizeForJSON(_ text: String) -> String {
    text.unicodeScalars.filter { scalar in
        // 허용: 일반 텍스트 + 개행(\n, \r) + 탭(\t)
        scalar.value >= 0x20 || scalar == "\n" || scalar == "\r" || scalar == "\t"
    }.map { String($0) }.joined()
}

/// 타입을 알 수 없는 JSON 값을 무시하기 위한 래퍼
struct AnyCodableValue: Codable {
    init(from decoder: Decoder) throws {
        // 어떤 값이든 디코딩만 하고 버림
        _ = try? decoder.singleValueContainer()
    }
    func encode(to encoder: Encoder) throws {}
}

struct OpenAIChatResponse: Content {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIChoice]
    let usage: OpenAIUsage
}

struct OpenAIChoice: Content {
    let index: Int
    let message: OpenAIChatMessage
    let finishReason: String
}

struct OpenAIUsage: Content {
    let promptTokens: Int
    let completionTokens: Int
    let totalTokens: Int
}

// MARK: - OpenAI Streaming DTOs

struct OpenAIStreamChunk: Codable {
    let id: String
    let object: String
    let created: Int
    let model: String
    let choices: [OpenAIStreamChoice]
}

struct OpenAIStreamChoice: Codable {
    let index: Int
    let delta: OpenAIStreamDelta
    let finishReason: String?
}

struct OpenAIStreamDelta: Codable {
    let role: String?
    let content: String?
}

struct OpenAIModelsResponse: Content {
    let object: String
    let data: [OpenAIModel]
}

struct OpenAIModel: Content {
    let id: String
    let object: String
    let created: Int
    let ownedBy: String
}
