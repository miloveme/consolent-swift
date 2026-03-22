import Foundation
import Vapor

/// 임베디드 Vapor HTTP/WebSocket 서버.
/// macOS 앱 내에서 백그라운드로 동작한다.
final class APIServer: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var serverError: String?
    @Published private(set) var connectionCount = 0

    private var app: Application?
    private let sessionManager: SessionManager
    private let mcpHandler: MCPHandler

    init(sessionManager: SessionManager = .shared) {
        self.sessionManager = sessionManager
        self.mcpHandler = MCPHandler(sessionManager: sessionManager)
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

        // 요청 body 크기 제한 (기본 16KB → 10MB)
        // OpenAI 호환 클라이언트가 대화 히스토리를 포함해 보내므로 충분히 확보
        app.routes.defaultMaxBodySize = "10mb"

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
        mcpHandler.registerRoutes(on: authGroup)

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
                channelServerName: body.channelServerName ?? "openai-compat"
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
                channelUrl: session.channelServerURL
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
                channelUrl: session.channelServerURL
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
                channelUrl: session.channelServerURL
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
            guard let lastUserMsg = body.messages.last(where: { $0.role == "user" }),
                  !lastUserMsg.textContent.isEmpty else {
                throw Abort(.badRequest, reason: "No user message found")
            }
            let lastUserMessage = lastUserMsg.textContent
            print("[API] 메시지: \(lastUserMessage.prefix(50))")

            // 세션 해결: model 필드로 이름 매칭, 없으면 기존 폴백
            let session = try await resolveSession(model: body.model)
            let timeout = TimeInterval(body.timeout ?? 300)
            print("[API] 세션: \(session.id), status=\(session.status.rawValue)")

            // 디버그 로깅: API 요청
            DebugLogger.shared.logAPIRequest(
                sessionId: session.id, method: "POST", path: "/v1/chat/completions",
                model: body.model, message: lastUserMessage, streaming: body.stream ?? false
            )

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
                            let contentChunk = OpenAIStreamChunk(
                                id: completionId, object: "chat.completion.chunk",
                                created: created, model: modelId,
                                choices: [OpenAIStreamChoice(
                                    index: 0,
                                    delta: OpenAIStreamDelta(role: nil, content: text),
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
            let responseText = result.response.result

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

    /// OpenAI 호환 API용 세션 해결.
    /// model 필드가 있으면 세션 이름으로 매칭, 없으면 기존 폴백 로직 사용.
    /// 채널 모드 세션은 Consolent API 라우팅에서 제외 — 채널 서버 URL로 안내.
    private func resolveSession(model: String?) async throws -> Session {
        // model 필드로 세션 이름 매칭
        if let model = model, !model.isEmpty {
            if let session = sessionManager.getSession(name: model) {
                // 채널 모드 세션은 Consolent API에서 처리하지 않음
                if session.isChannelMode {
                    let channelUrl = session.channelServerURL ?? "http://localhost:\(session.config.channelPort)"
                    throw Abort(.gone, reason: "Session '\(model)' is in channel mode. Send requests directly to \(channelUrl)/v1")
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
    /// 채널 모드 세션은 폴백 대상에서 제외.
    private func getOrCreateDefaultSession() async throws -> Session {
        // 1. 이전에 고정된 세션이 ready + 비채널이면 계속 사용 (대화 컨텍스트 유지)
        if let id = defaultSessionId, let session = sessionManager.getSession(id: id),
           session.status == .ready, !session.isChannelMode {
            return session
        }

        // 2. 앱에서 현재 선택된 세션이 ready + 비채널이면 사용
        if let selected = sessionManager.selectedSession,
           selected.status == .ready, !selected.isChannelMode {
            defaultSessionId = selected.id
            return selected
        }

        // 3. 아무 ready + 비채널 세션이라도 사용
        let readySessions = sessionManager.listSessions().filter { $0.status == .ready && !$0.channelEnabled }
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
    // OpenAI 호환 클라이언트가 보내는 추가 필드 (무시하되 디코딩 에러 방지)
    var topP: Double?
    var n: Int?
    var stop: AnyCodableValue?
    var presencePenalty: Double?
    var frequencyPenalty: Double?
    var user: String?
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
