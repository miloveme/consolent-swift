import Foundation
import Vapor

// MARK: - MCP Protocol Handler

/// MCP (Model Context Protocol) Streamable HTTP 핸들러.
/// Consolent의 세션 관리 기능을 MCP 도구로 노출하여 AI 에이전트가 직접 사용할 수 있게 한다.
///
/// 지원 트랜스포트: Streamable HTTP (POST /mcp)
/// 프로토콜: JSON-RPC 2.0
final class MCPHandler {

    private let sessionManager: SessionManager

    // MCP 프로토콜 버전
    private let protocolVersion = "2025-03-26"

    // 서버 정보
    private let serverInfo = MCPServerInfo(
        name: "consolent",
        version: "0.1.8"
    )

    init(sessionManager: SessionManager = .shared) {
        self.sessionManager = sessionManager
    }

    // MARK: - Route Registration

    /// Vapor 라우터에 MCP 엔드포인트 등록
    func registerRoutes(on router: RoutesBuilder) {

        // POST /mcp — MCP Streamable HTTP 엔드포인트
        router.post("mcp") { [self] req -> Response in
            let jsonRPC = try req.content.decode(JSONRPCRequest.self)
            let result = await handleRequest(jsonRPC)

            // notification (id == nil) 이면 204 No Content
            guard let _ = jsonRPC.id else {
                return Response(status: .noContent)
            }

            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(result)

            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // GET /mcp — SSE 엔드포인트 (Streamable HTTP 스펙, 현재는 미구현)
        router.get("mcp") { req -> Response in
            // SSE 스트림은 서버→클라이언트 알림용. 현재는 도구 호출만 지원하므로 비활성.
            return Response(
                status: .methodNotAllowed,
                headers: ["Content-Type": "application/json"],
                body: .init(string: #"{"error":"SSE stream not implemented. Use POST /mcp for tool calls."}"#)
            )
        }
    }

    // MARK: - JSON-RPC Dispatch

    private func handleRequest(_ request: JSONRPCRequest) async -> JSONRPCResponse {
        let id = request.id ?? .string("null")

        switch request.method {
        case "initialize":
            return handleInitialize(id: id, params: request.params)
        case "notifications/initialized":
            // 클라이언트 초기화 완료 알림 — 응답 불필요
            return JSONRPCResponse(jsonrpc: "2.0", id: id, result: nil, error: nil)
        case "ping":
            return JSONRPCResponse(jsonrpc: "2.0", id: id, result: .object([:]), error: nil)
        case "tools/list":
            return handleToolsList(id: id)
        case "tools/call":
            return await handleToolsCall(id: id, params: request.params)
        case "resources/list":
            return handleResourcesList(id: id)
        case "resources/read":
            return await handleResourcesRead(id: id, params: request.params)
        default:
            return JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32601, message: "Method not found: \(request.method)")
            )
        }
    }

    // MARK: - initialize

    private func handleInitialize(id: JSONRPCId, params: JSONValue?) -> JSONRPCResponse {
        let capabilities = MCPCapabilities(
            tools: MCPToolCapability(listChanged: false),
            resources: MCPResourceCapability(subscribe: false, listChanged: false)
        )

        let result = MCPInitializeResult(
            protocolVersion: protocolVersion,
            capabilities: capabilities,
            serverInfo: serverInfo
        )

        return JSONRPCResponse(jsonrpc: "2.0", id: id, result: .encodable(result), error: nil)
    }

    // MARK: - tools/list

    private func handleToolsList(id: JSONRPCId) -> JSONRPCResponse {
        let tools: [MCPToolDefinition] = [
            MCPToolDefinition(
                name: "session_create",
                description: "터미널에서 AI CLI 도구 세션을 생성합니다. 지원 CLI: claude-code, codex, gemini. 세션이 ready 상태가 되면 메시지를 보낼 수 있습니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "cli_type": .object([
                            "type": .string("string"),
                            "description": .string("CLI 도구 타입: claude-code, codex, gemini"),
                            "enum": .array([.string("claude-code"), .string("codex"), .string("gemini")])
                        ]),
                        "working_directory": .object([
                            "type": .string("string"),
                            "description": .string("작업 디렉토리 경로 (절대 경로)")
                        ]),
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("세션 이름 (생략 시 CLI 타입명 자동 부여)")
                        ]),
                        "auto_approve": .object([
                            "type": .string("boolean"),
                            "description": .string("자동 승인 모드 (--dangerously-skip-permissions). 기본: false")
                        ]),
                        "cli_args": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("CLI에 전달할 추가 인자")
                        ])
                    ]),
                    "required": .array([.string("cli_type")])
                ])
            ),
            MCPToolDefinition(
                name: "session_list",
                description: "모든 활성 세션 목록을 조회합니다. 각 세션의 ID, 이름, 상태, CLI 타입, 작업 디렉토리 등을 반환합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ),
            MCPToolDefinition(
                name: "session_get",
                description: "특정 세션의 상세 정보를 조회합니다. 세션 상태, 통계, 대기 중인 승인 요청 등을 포함합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("세션 ID")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "session_delete",
                description: "세션을 종료하고 삭제합니다. CLI 프로세스가 종료되고 PTY가 정리됩니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("삭제할 세션 ID")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "session_send_message",
                description: "세션에 메시지를 보내고 응답을 기다립니다. CLI 도구가 응답을 완료할 때까지 대기하는 동기 호출입니다. 타임아웃 기본값은 300초입니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("메시지를 보낼 세션 ID")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("보낼 메시지 텍스트")
                        ]),
                        "timeout": .object([
                            "type": .string("integer"),
                            "description": .string("응답 대기 타임아웃 (초). 기본: 300")
                        ])
                    ]),
                    "required": .array([.string("session_id"), .string("text")])
                ])
            ),
            MCPToolDefinition(
                name: "session_input",
                description: "세션의 PTY에 원시 입력을 주입합니다. 특수 키(ctrl+c, enter 등)나 임의 텍스트를 보낼 수 있습니다. 응답을 기다리지 않습니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("입력을 보낼 세션 ID")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("보낼 텍스트 (text 또는 keys 중 하나 필수)")
                        ]),
                        "keys": .object([
                            "type": .string("array"),
                            "items": .object(["type": .string("string")]),
                            "description": .string("특수 키 시퀀스: ctrl+c, ctrl+d, enter, escape, tab, up, down, left, right")
                        ])
                    ])
                ])
            ),
            MCPToolDefinition(
                name: "session_output",
                description: "세션의 현재 터미널 출력 버퍼를 조회합니다. ANSI 코드가 제거된 텍스트와 원시 출력 모두 반환합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("출력을 조회할 세션 ID")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "session_approve",
                description: "대기 중인 승인 요청에 응답합니다. CLI 도구가 파일 수정 등의 권한을 요청할 때 승인하거나 거부할 수 있습니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("세션 ID")
                        ]),
                        "approval_id": .object([
                            "type": .string("string"),
                            "description": .string("승인 요청 ID")
                        ]),
                        "approved": .object([
                            "type": .string("boolean"),
                            "description": .string("승인 여부. true = 승인, false = 거부")
                        ])
                    ]),
                    "required": .array([.string("session_id"), .string("approval_id"), .string("approved")])
                ])
            ),
            MCPToolDefinition(
                name: "session_pending",
                description: "세션에서 대기 중인 승인 요청 목록을 조회합니다. 승인이 필요한 작업이 있는지 확인할 때 사용합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("세션 ID")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            )
        ]

        let result: JSONValue = .object([
            "tools": .array(tools.map { tool in
                .object([
                    "name": .string(tool.name),
                    "description": .string(tool.description),
                    "inputSchema": tool.inputSchema
                ])
            })
        ])

        return JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    // MARK: - tools/call

    private func handleToolsCall(id: JSONRPCId, params: JSONValue?) async -> JSONRPCResponse {
        guard let params = params,
              case .object(let dict) = params,
              case .string(let toolName)? = dict["name"] else {
            return JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32602, message: "Missing tool name in params")
            )
        }

        let arguments: [String: JSONValue]
        if case .object(let args)? = dict["arguments"] {
            arguments = args
        } else {
            arguments = [:]
        }

        do {
            let result = try await executeTool(name: toolName, arguments: arguments)
            return JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
        } catch {
            let toolResult: JSONValue = .object([
                "content": .array([
                    .object([
                        "type": .string("text"),
                        "text": .string("Error: \(error.localizedDescription)")
                    ])
                ]),
                "isError": .bool(true)
            ])
            return JSONRPCResponse(jsonrpc: "2.0", id: id, result: toolResult, error: nil)
        }
    }

    // MARK: - Tool Execution

    private func executeTool(name: String, arguments: [String: JSONValue]) async throws -> JSONValue {
        switch name {
        case "session_create":
            return try await toolSessionCreate(arguments)
        case "session_list":
            return toolSessionList()
        case "session_get":
            return try toolSessionGet(arguments)
        case "session_delete":
            return try await toolSessionDelete(arguments)
        case "session_send_message":
            return try await toolSessionSendMessage(arguments)
        case "session_input":
            return try toolSessionInput(arguments)
        case "session_output":
            return try toolSessionOutput(arguments)
        case "session_approve":
            return try toolSessionApprove(arguments)
        case "session_pending":
            return try toolSessionPending(arguments)
        default:
            throw MCPError.toolNotFound(name)
        }
    }

    // MARK: - Tool Implementations

    private func toolSessionCreate(_ args: [String: JSONValue]) async throws -> JSONValue {
        let cliTypeStr = args["cli_type"]?.stringValue ?? "claude-code"
        guard let cliType = CLIType(rawValue: cliTypeStr) else {
            throw MCPError.invalidParameter("cli_type", "지원하지 않는 CLI 타입: \(cliTypeStr). 가능한 값: claude-code, codex, gemini")
        }

        let config = Session.Config(
            name: args["name"]?.stringValue,
            workingDirectory: args["working_directory"]?.stringValue ?? AppConfig.shared.cwd(for: cliType),
            shell: AppConfig.shared.defaultShell,
            cliType: cliType,
            cliArgs: args["cli_args"]?.stringArrayValue ?? [],
            autoApprove: args["auto_approve"]?.boolValue ?? false,
            idleTimeout: AppConfig.shared.sessionIdleTimeout,
            env: nil,
            channelEnabled: false,
            channelPort: 8787,
            channelServerName: "openai-compat"
        )

        let session = try await sessionManager.createSession(config: config)

        return mcpTextResult("""
        세션 생성 완료.
        - session_id: \(session.id)
        - name: \(session.name)
        - status: \(session.status.rawValue)
        - cli_type: \(cliTypeStr)
        - working_directory: \(config.workingDirectory)

        세션이 ready 상태가 되면 session_send_message로 메시지를 보낼 수 있습니다.
        현재 상태를 확인하려면 session_get을 사용하세요.
        """)
    }

    private func toolSessionList() -> JSONValue {
        let sessions = sessionManager.listSessions()

        if sessions.isEmpty {
            return mcpTextResult("활성 세션이 없습니다. session_create로 새 세션을 만드세요.")
        }

        var lines = ["활성 세션 목록 (\(sessions.count)개):"]
        for s in sessions {
            lines.append("- [\(s.id)] \(s.name) | status: \(s.status.rawValue) | cli: \(s.cliType) | dir: \(s.workingDirectory)")
        }

        return mcpTextResult(lines.joined(separator: "\n"))
    }

    private func toolSessionGet(_ args: [String: JSONValue]) throws -> JSONValue {
        let sessionId = try requireString(args, "session_id")
        guard let session = sessionManager.getSession(id: sessionId) else {
            throw MCPError.sessionNotFound(sessionId)
        }

        var lines = [
            "세션 상세:",
            "- id: \(session.id)",
            "- name: \(session.name)",
            "- status: \(session.status.rawValue)",
            "- working_directory: \(session.config.workingDirectory)",
            "- cli_type: \(session.config.cliType.rawValue)",
            "- messages_sent: \(session.messageCount)",
            "- uptime: \(Int(Date().timeIntervalSince(session.createdAt)))초"
        ]

        if let pending = session.pendingApproval {
            lines.append("- pending_approval:")
            lines.append("  - id: \(pending.id)")
            lines.append("  - prompt: \(pending.prompt)")
        }

        return mcpTextResult(lines.joined(separator: "\n"))
    }

    private func toolSessionDelete(_ args: [String: JSONValue]) async throws -> JSONValue {
        let sessionId = try requireString(args, "session_id")
        guard sessionManager.getSession(id: sessionId) != nil else {
            throw MCPError.sessionNotFound(sessionId)
        }

        await MainActor.run {
            sessionManager.deleteSession(id: sessionId)
        }

        return mcpTextResult("세션 \(sessionId) 삭제 완료.")
    }

    private func toolSessionSendMessage(_ args: [String: JSONValue]) async throws -> JSONValue {
        let sessionId = try requireString(args, "session_id")
        let text = try requireString(args, "text")
        let timeout = TimeInterval(args["timeout"]?.intValue ?? 300)

        guard let session = sessionManager.getSession(id: sessionId) else {
            throw MCPError.sessionNotFound(sessionId)
        }

        guard session.status == .ready else {
            throw MCPError.sessionNotReady(sessionId, session.status.rawValue)
        }

        let result = try await session.sendMessage(text: text, timeout: timeout)
        let responseText = result.response.result

        return mcpTextResult(responseText)
    }

    private func toolSessionInput(_ args: [String: JSONValue]) throws -> JSONValue {
        let sessionId = try requireString(args, "session_id")
        guard let session = sessionManager.getSession(id: sessionId) else {
            throw MCPError.sessionNotFound(sessionId)
        }

        if let text = args["text"]?.stringValue {
            try session.injectInput(text: text)
            return mcpTextResult("입력 전송 완료: \(text.prefix(50))")
        } else if let keys = args["keys"]?.stringArrayValue {
            for key in keys {
                if let data = keyToBytes(key) {
                    try session.injectInput(data: data)
                }
            }
            return mcpTextResult("키 입력 전송 완료: \(keys.joined(separator: ", "))")
        } else {
            throw MCPError.invalidParameter("text/keys", "text 또는 keys 중 하나는 필수입니다.")
        }
    }

    private func toolSessionOutput(_ args: [String: JSONValue]) throws -> JSONValue {
        let sessionId = try requireString(args, "session_id")
        guard let session = sessionManager.getSession(id: sessionId) else {
            throw MCPError.sessionNotFound(sessionId)
        }

        let raw = String(data: session.outputBuffer, encoding: .utf8) ?? ""
        let text = OutputParser.stripANSI(raw)

        return mcpTextResult(text.isEmpty ? "(출력 없음)" : text)
    }

    private func toolSessionApprove(_ args: [String: JSONValue]) throws -> JSONValue {
        let sessionId = try requireString(args, "session_id")
        let approvalId = try requireString(args, "approval_id")
        let approved = args["approved"]?.boolValue ?? true

        guard let session = sessionManager.getSession(id: sessionId) else {
            throw MCPError.sessionNotFound(sessionId)
        }

        try session.respondToApproval(id: approvalId, approved: approved)

        return mcpTextResult(approved ? "승인 완료 (approval_id: \(approvalId))" : "거부 완료 (approval_id: \(approvalId))")
    }

    private func toolSessionPending(_ args: [String: JSONValue]) throws -> JSONValue {
        let sessionId = try requireString(args, "session_id")
        guard let session = sessionManager.getSession(id: sessionId) else {
            throw MCPError.sessionNotFound(sessionId)
        }

        if let pending = session.pendingApproval {
            return mcpTextResult("""
            대기 중인 승인 요청:
            - id: \(pending.id)
            - prompt: \(pending.prompt)
            - detected_at: \(pending.detectedAt)

            session_approve 도구로 승인/거부할 수 있습니다.
            """)
        } else {
            return mcpTextResult("대기 중인 승인 요청이 없습니다.")
        }
    }

    // MARK: - resources/list

    private func handleResourcesList(id: JSONRPCId) -> JSONRPCResponse {
        // 동적 리소스: 각 세션의 출력을 리소스로 노출
        let sessions = sessionManager.listSessions()
        var resources: [JSONValue] = []

        for s in sessions {
            resources.append(.object([
                "uri": .string("consolent://sessions/\(s.id)/output"),
                "name": .string("\(s.name) - Terminal Output"),
                "description": .string("세션 '\(s.name)'의 현재 터미널 출력"),
                "mimeType": .string("text/plain")
            ]))
        }

        let result: JSONValue = .object([
            "resources": .array(resources)
        ])

        return JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    // MARK: - resources/read

    private func handleResourcesRead(id: JSONRPCId, params: JSONValue?) async -> JSONRPCResponse {
        guard let params = params,
              case .object(let dict) = params,
              case .string(let uri)? = dict["uri"] else {
            return JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32602, message: "Missing uri in params")
            )
        }

        // consolent://sessions/{id}/output 파싱
        let prefix = "consolent://sessions/"
        guard uri.hasPrefix(prefix), uri.hasSuffix("/output") else {
            return JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32602, message: "Unknown resource URI: \(uri)")
            )
        }

        let sessionId = String(uri.dropFirst(prefix.count).dropLast("/output".count))
        guard let session = sessionManager.getSession(id: sessionId) else {
            return JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32602, message: "Session not found: \(sessionId)")
            )
        }

        let raw = String(data: session.outputBuffer, encoding: .utf8) ?? ""
        let text = OutputParser.stripANSI(raw)

        let result: JSONValue = .object([
            "contents": .array([
                .object([
                    "uri": .string(uri),
                    "mimeType": .string("text/plain"),
                    "text": .string(text)
                ])
            ])
        ])

        return JSONRPCResponse(jsonrpc: "2.0", id: id, result: result, error: nil)
    }

    // MARK: - Helpers

    private func mcpTextResult(_ text: String) -> JSONValue {
        return .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ])
        ])
    }

    private func requireString(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, !value.isEmpty else {
            throw MCPError.invalidParameter(key, "\(key)은(는) 필수 파라미터입니다.")
        }
        return value
    }

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

// MARK: - MCP Errors

enum MCPError: LocalizedError {
    case toolNotFound(String)
    case sessionNotFound(String)
    case sessionNotReady(String, String)
    case invalidParameter(String, String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let name):
            return "도구를 찾을 수 없습니다: \(name)"
        case .sessionNotFound(let id):
            return "세션을 찾을 수 없습니다: \(id). session_list로 활성 세션을 확인하세요."
        case .sessionNotReady(let id, let status):
            return "세션 \(id)이(가) ready 상태가 아닙니다 (현재: \(status)). 잠시 후 다시 시도하세요."
        case .invalidParameter(let param, let reason):
            return "잘못된 파라미터 '\(param)': \(reason)"
        }
    }
}

// MARK: - JSON-RPC 2.0 Types

enum JSONRPCId: Codable, Equatable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else {
            self = .string("null")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        }
    }
}

struct JSONRPCRequest: Content {
    let jsonrpc: String
    let id: JSONRPCId?
    let method: String
    let params: JSONValue?
}

struct JSONRPCResponse: Codable {
    let jsonrpc: String
    let id: JSONRPCId
    var result: JSONValue?
    var error: JSONRPCError?
}

struct JSONRPCError: Codable {
    let code: Int
    let message: String
}

/// 범용 JSON 값 타입 — MCP 프로토콜의 유연한 파라미터/결과를 처리한다.
indirect enum JSONValue: Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    // 편의 접근자
    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var intValue: Int? {
        if case .int(let i) = self { return i }
        if case .double(let d) = self { return Int(d) }
        return nil
    }
    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }
    var stringArrayValue: [String]? {
        if case .array(let arr) = self {
            return arr.compactMap { $0.stringValue }
        }
        return nil
    }

    /// Encodable 인스턴스를 JSONValue로 변환
    static func encodable<T: Encodable>(_ value: T) -> JSONValue {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(value),
              let json = try? JSONSerialization.jsonObject(with: data),
              let result = JSONValue.from(json) else {
            return .null
        }
        return result
    }

    private static func from(_ any: Any) -> JSONValue? {
        if let dict = any as? [String: Any] {
            var obj: [String: JSONValue] = [:]
            for (k, v) in dict {
                obj[k] = from(v) ?? .null
            }
            return .object(obj)
        } else if let arr = any as? [Any] {
            return .array(arr.compactMap { from($0) })
        } else if let s = any as? String {
            return .string(s)
        } else if let b = any as? Bool {
            return .bool(b)
        } else if let i = any as? Int {
            return .int(i)
        } else if let d = any as? Double {
            return .double(d)
        } else if any is NSNull {
            return .null
        }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let b = try? container.decode(Bool.self) {
            self = .bool(b)
        } else if let i = try? container.decode(Int.self) {
            self = .int(i)
        } else if let d = try? container.decode(Double.self) {
            self = .double(d)
        } else if let s = try? container.decode(String.self) {
            self = .string(s)
        } else if let arr = try? container.decode([JSONValue].self) {
            self = .array(arr)
        } else if let obj = try? container.decode([String: JSONValue].self) {
            self = .object(obj)
        } else {
            self = .null
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .object(let o): try container.encode(o)
        case .array(let a): try container.encode(a)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - MCP Protocol Types

struct MCPServerInfo: Codable {
    let name: String
    let version: String
}

struct MCPCapabilities: Codable {
    let tools: MCPToolCapability?
    let resources: MCPResourceCapability?
}

struct MCPToolCapability: Codable {
    let listChanged: Bool
}

struct MCPResourceCapability: Codable {
    let subscribe: Bool
    let listChanged: Bool
}

struct MCPInitializeResult: Codable {
    let protocolVersion: String
    let capabilities: MCPCapabilities
    let serverInfo: MCPServerInfo
}

struct MCPToolDefinition {
    let name: String
    let description: String
    let inputSchema: JSONValue
}
