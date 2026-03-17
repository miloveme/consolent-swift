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
                workingDirectory: body.workingDirectory ?? AppConfig.shared.defaultCwd,
                shell: body.shell ?? AppConfig.shared.defaultShell,
                cliType: cliType,
                cliArgs: body.cliArgs ?? body.claudeArgs ?? [],
                autoApprove: body.autoApprove ?? false,
                idleTimeout: body.idleTimeout ?? AppConfig.shared.sessionIdleTimeout,
                env: body.env
            )

            let session = try await sessionManager.createSession(config: config)

            let appCfg = AppConfig.shared
            let bindHost = appCfg.apiBind == "0.0.0.0" ? "127.0.0.1" : appCfg.apiBind
            let localUrl = "http://\(bindHost):\(appCfg.apiPort)"

            let response = CreateSessionResponse(
                sessionId: session.id,
                status: session.status,
                createdAt: session.createdAt,
                localUrl: localUrl,
                tunnelUrl: session.tunnelURL  // 터널 준비 전이면 nil; GET /sessions/:id 로 재조회 가능
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
                tunnelUrl: session.tunnelURL
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

        // GET /v1/models — 모델 목록 (지원하는 모든 CLI 유형)
        router.get("v1", "models") { req -> OpenAIModelsResponse in
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
            let body = try req.content.decode(OpenAIChatRequest.self)

            // 마지막 user 메시지 추출
            guard let lastUserMsg = body.messages.last(where: { $0.role == "user" }),
                  !lastUserMsg.textContent.isEmpty else {
                throw Abort(.badRequest, reason: "No user message found")
            }
            let lastUserMessage = lastUserMsg.textContent

            // 세션 가져오기 또는 생성
            let session = try await getOrCreateDefaultSession()

            // 메시지 전송
            let timeout = TimeInterval(body.timeout ?? 300)
            let result = try await session.sendMessage(text: lastUserMessage, timeout: timeout)

            let completionId = "chatcmpl-\(result.messageId)"
            let created = Int(Date().timeIntervalSince1970)
            let modelId = session.adapter.modelId
            let responseText = result.response.result

            // stream 모드: SSE (Server-Sent Events) 형식
            if body.stream == true {
                let encoder = JSONEncoder()
                encoder.keyEncodingStrategy = .convertToSnakeCase

                // 1. role chunk
                let roleChunk = OpenAIStreamChunk(
                    id: completionId, object: "chat.completion.chunk",
                    created: created, model: modelId,
                    choices: [OpenAIStreamChoice(
                        index: 0,
                        delta: OpenAIStreamDelta(role: "assistant", content: nil),
                        finishReason: nil
                    )]
                )

                // 2. content chunk (전체 응답)
                let contentChunk = OpenAIStreamChunk(
                    id: completionId, object: "chat.completion.chunk",
                    created: created, model: modelId,
                    choices: [OpenAIStreamChoice(
                        index: 0,
                        delta: OpenAIStreamDelta(role: nil, content: responseText),
                        finishReason: nil
                    )]
                )

                // 3. finish chunk
                let finishChunk = OpenAIStreamChunk(
                    id: completionId, object: "chat.completion.chunk",
                    created: created, model: modelId,
                    choices: [OpenAIStreamChoice(
                        index: 0,
                        delta: OpenAIStreamDelta(role: nil, content: nil),
                        finishReason: "stop"
                    )]
                )

                var sseBody = ""
                if let d = try? encoder.encode(roleChunk), let s = String(data: d, encoding: .utf8) {
                    sseBody += "data: \(s)\n\n"
                }
                if let d = try? encoder.encode(contentChunk), let s = String(data: d, encoding: .utf8) {
                    sseBody += "data: \(s)\n\n"
                }
                if let d = try? encoder.encode(finishChunk), let s = String(data: d, encoding: .utf8) {
                    sseBody += "data: \(s)\n\n"
                }
                sseBody += "data: [DONE]\n\n"

                return Response(
                    status: .ok,
                    headers: [
                        "Content-Type": "text/event-stream",
                        "Cache-Control": "no-cache",
                        "Connection": "keep-alive"
                    ],
                    body: .init(string: sseBody)
                )
            }

            // 비-stream 모드: 일반 JSON
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

    /// OpenAI 호환 API용 세션을 가져온다.
    /// 우선순위: 고정된 세션 → 앱에서 선택된 세션 → 아무 ready 세션 → 에러
    private func getOrCreateDefaultSession() async throws -> Session {
        // 1. 이전에 고정된 세션이 ready면 계속 사용 (대화 컨텍스트 유지)
        if let id = defaultSessionId, let session = sessionManager.getSession(id: id),
           session.status == .ready {
            return session
        }

        // 2. 앱에서 현재 선택된 세션이 ready면 사용
        if let selected = sessionManager.selectedSession, selected.status == .ready {
            defaultSessionId = selected.id
            return selected
        }

        // 3. 아무 ready 세션이라도 사용
        let readySessions = sessionManager.listSessions().filter { $0.status == .ready }
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
    var workingDirectory: String?
    var shell: String?
    var cliType: String?
    var cliArgs: [String]?
    var claudeArgs: [String]?  // 하위 호환용
    var autoApprove: Bool?
    var idleTimeout: Int?
    var env: [String: String]?
}

struct CreateSessionResponse: Content {
    let sessionId: String
    let status: Session.Status
    let createdAt: Date
    let localUrl: String
    let tunnelUrl: String?
}

struct SessionStatusResponse: Content {
    let id: String
    let status: Session.Status
    let workingDirectory: String
    let pendingApproval: ApprovalInfo?
    let stats: SessionStats
    let localUrl: String
    let tunnelUrl: String?
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
