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

            // notification (id == nil) 이면 204 No Content
            guard let id = jsonRPC.id else {
                _ = await handleRequest(jsonRPC)
                return Response(status: .noContent)
            }

            // tools/call + stream: true 이면 SSE 스트리밍 응답
            if jsonRPC.method == "tools/call",
               case .object(let params)? = jsonRPC.params,
               case .string(let toolName)? = params["name"],
               toolName == "session_send_message",
               case .object(let args)? = params["arguments"],
               args["stream"]?.boolValue == true {
                return try await handleStreamingToolCall(id: id, arguments: args)
            }

            let result = await handleRequest(jsonRPC)
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
            return Response(
                status: .methodNotAllowed,
                headers: ["Content-Type": "application/json"],
                body: .init(string: #"{"error":"SSE stream not implemented. Use POST /mcp for tool calls."}"#)
            )
        }
    }

    // MARK: - Streaming Tool Call

    /// session_send_message의 스트리밍 응답.
    /// MCP Streamable HTTP 스펙에 따라 SSE로 progress notification + 최종 result를 전송한다.
    private func handleStreamingToolCall(id: JSONRPCId, arguments: [String: JSONValue]) async throws -> Response {
        let session: Session
        do {
            session = try resolveSession(arguments)
        } catch {
            let errorResponse = JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32602, message: error.localizedDescription)
            )
            let data = (try? JSONEncoder().encode(errorResponse)) ?? Data()
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
            let errorResponse = JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32602, message: "text는 필수 파라미터입니다.")
            )
            let data = (try? JSONEncoder().encode(errorResponse)) ?? Data()
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        if session.status == .stopped || session.status == .error {
            let errorResponse = JSONRPCResponse(
                jsonrpc: "2.0", id: id, result: nil,
                error: JSONRPCError(code: -32603, message: "세션이 \(session.status.rawValue) 상태입니다. session_start로 재시작 후 시도하세요.")
            )
            let data = (try? JSONEncoder().encode(errorResponse)) ?? Data()
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        let timeout = TimeInterval(arguments["timeout"]?.intValue ?? 300)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase

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
            let stream = session.sendMessageStreaming(text: text, timeout: timeout)
            var fullText = ""

            for await event in stream {
                switch event {
                case .delta(let chunk):
                    fullText += chunk
                    // MCP progress notification — 델타 청크를 실시간 전송
                    let notification: [String: Any] = [
                        "jsonrpc": "2.0",
                        "method": "notifications/progress",
                        "params": [
                            "progressToken": "\(id)",
                            "progress": chunk,
                            "total": ""
                        ]
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: notification),
                       let line = String(data: data, encoding: .utf8) {
                        var buf = ByteBufferAllocator().buffer(capacity: line.utf8.count + 8)
                        buf.writeString("data: \(line)\n\n")
                        try await writer.writeBuffer(buf)
                    }

                case .done:
                    // 최종 tools/call result
                    let finalResult = JSONRPCResponse(
                        jsonrpc: "2.0", id: id,
                        result: .object([
                            "content": .array([
                                .object(["type": .string("text"), "text": .string(fullText)])
                            ])
                        ]),
                        error: nil
                    )
                    if let data = try? encoder.encode(finalResult),
                       let line = String(data: data, encoding: .utf8) {
                        var buf = ByteBufferAllocator().buffer(capacity: line.utf8.count + 8)
                        buf.writeString("data: \(line)\n\n")
                        try await writer.writeBuffer(buf)
                    }

                case .error(let msg):
                    let errorResponse = JSONRPCResponse(
                        jsonrpc: "2.0", id: id, result: nil,
                        error: JSONRPCError(code: -32603, message: msg)
                    )
                    if let data = try? encoder.encode(errorResponse),
                       let line = String(data: data, encoding: .utf8) {
                        var buf = ByteBufferAllocator().buffer(capacity: line.utf8.count + 8)
                        buf.writeString("data: \(line)\n\n")
                        try await writer.writeBuffer(buf)
                    }
                }
            }
        })

        return response
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
                description: "터미널에서 AI CLI 도구 세션을 생성합니다. 지원 CLI: claude-code, codex, gemini. PTY 모드(기본) 외에 브릿지 모드(sdk/gemini_stream/codex_app_server)도 지원합니다.",
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
                        ]),
                        "channel_enabled": .object([
                            "type": .string("boolean"),
                            "description": .string("채널 서버 모드 활성화 (claude-code 전용). MCP 채널 서버로 직접 API 제공. 기본: false")
                        ]),
                        "channel_port": .object([
                            "type": .string("integer"),
                            "description": .string("채널 서버 HTTP 포트. 기본: 8787")
                        ]),
                        "channel_server_name": .object([
                            "type": .string("string"),
                            "description": .string("~/.claude.json의 mcpServers 키. 기본: openai-compat")
                        ]),
                        "sdk_enabled": .object([
                            "type": .string("boolean"),
                            "description": .string("Agent SDK 브릿지 모드 활성화 (claude-code 전용). PTY 없이 Claude Agent SDK로 직접 통신. 기본: false")
                        ]),
                        "sdk_port": .object([
                            "type": .string("integer"),
                            "description": .string("SDK 브릿지 서버 포트. 기본: 8788")
                        ]),
                        "sdk_model": .object([
                            "type": .string("string"),
                            "description": .string("SDK 모드에서 사용할 모델 (예: claude-sonnet-4-20250514)")
                        ]),
                        "sdk_permission_mode": .object([
                            "type": .string("string"),
                            "description": .string("SDK 퍼미션 모드: acceptEdits, bypassPermissions. 기본: acceptEdits")
                        ]),
                        "gemini_stream_enabled": .object([
                            "type": .string("boolean"),
                            "description": .string("Gemini Stream 브릿지 모드 활성화 (gemini 전용). 기본: false")
                        ]),
                        "gemini_stream_port": .object([
                            "type": .string("integer"),
                            "description": .string("Gemini 브릿지 서버 포트. 기본: 8789")
                        ]),
                        "codex_app_server_enabled": .object([
                            "type": .string("boolean"),
                            "description": .string("Codex App Server 브릿지 모드 활성화 (codex 전용). 기본: false")
                        ]),
                        "codex_app_server_port": .object([
                            "type": .string("integer"),
                            "description": .string("Codex 브릿지 서버 포트. 기본: 8790")
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
                            "description": .string("세션 ID 또는 이름")
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
                name: "session_stop",
                description: "세션의 CLI 프로세스를 중지합니다. 세션 객체는 유지되므로 session_start로 재시작할 수 있습니다. 완전 삭제는 session_delete를 사용하세요.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("중지할 세션 ID 또는 이름")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "session_start",
                description: "중지(stopped) 또는 오류(error) 상태의 세션을 재시작합니다. session_stop으로 중지한 세션이나 오류로 종료된 세션을 다시 연결합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("재시작할 세션 ID 또는 이름")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "session_send_message",
                description: "세션에 메시지를 보내고 응답을 기다립니다. stream: true이면 SSE로 델타를 실시간 전송합니다. 타임아웃 기본값은 300초입니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("메시지를 보낼 세션 이름 또는 ID")
                        ]),
                        "text": .object([
                            "type": .string("string"),
                            "description": .string("보낼 메시지 텍스트")
                        ]),
                        "timeout": .object([
                            "type": .string("integer"),
                            "description": .string("응답 대기 타임아웃 (초). 기본: 300")
                        ]),
                        "stream": .object([
                            "type": .string("boolean"),
                            "description": .string("SSE 스트리밍 모드. true이면 MCP progress notification으로 델타를 실시간 전송. 기본: false")
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
                name: "session_rename",
                description: "세션 이름을 변경합니다. 이름은 OpenAI 호환 API의 model 필드로도 사용되므로 변경 시 클라이언트 설정도 함께 업데이트하세요.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("변경할 세션 이름 또는 ID")
                        ]),
                        "new_name": .object([
                            "type": .string("string"),
                            "description": .string("새 세션 이름 (중복 불가)")
                        ])
                    ]),
                    "required": .array([.string("session_id"), .string("new_name")])
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
                            "description": .string("세션 ID 또는 이름")
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
                            "description": .string("세션 ID 또는 이름")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "session_tunnel_start",
                description: "세션에 Cloudflare Quick Tunnel을 시작합니다. 터널이 연결되면 외부에서 접근 가능한 URL이 생성됩니다. session_get으로 tunnel_url을 확인할 수 있습니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("터널을 시작할 세션 이름 또는 ID")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "session_tunnel_stop",
                description: "세션의 Cloudflare Quick Tunnel을 중지합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "session_id": .object([
                            "type": .string("string"),
                            "description": .string("터널을 중지할 세션 이름 또는 ID")
                        ])
                    ]),
                    "required": .array([.string("session_id")])
                ])
            ),
            MCPToolDefinition(
                name: "config_get",
                description: "Consolent 앱의 현재 설정을 조회합니다. API 포트, 로그 레벨, CLI 기본값, 터미널 설정 등 모든 설정을 반환합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ),
            MCPToolDefinition(
                name: "config_update",
                description: "Consolent 앱의 설정을 변경합니다. 변경된 설정은 즉시 메모리와 파일 모두에 반영됩니다. 변경 가능한 키: log_level(off/fatal/info/debug), bridge_log_level(error/info/debug), default_cli_type(claude-code/codex/gemini), default_shell, max_concurrent_sessions, session_idle_timeout, font_family, font_size, theme, scrollback_lines, headless_terminal_rows, launch_to_menu_bar, include_raw_output, cwd_per_cli_type 등. 주의: api_port, api_bind 변경은 앱 재시작이 필요합니다.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "settings": .object([
                            "type": .string("object"),
                            "description": .string("변경할 설정 키-값 쌍. 예: {\"log_level\": \"off\", \"font_size\": 14}"),
                            "additionalProperties": .bool(true)
                        ])
                    ]),
                    "required": .array([.string("settings")])
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
        case "session_rename":
            return try toolSessionRename(arguments)
        case "session_stop":
            return try toolSessionStop(arguments)
        case "session_start":
            return try await toolSessionStart(arguments)
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
        case "session_tunnel_start":
            return try toolSessionTunnelStart(arguments)
        case "session_tunnel_stop":
            return try toolSessionTunnelStop(arguments)
        case "config_get":
            return await toolConfigGet()
        case "config_update":
            return try await toolConfigUpdate(arguments)
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

        let channelEnabled = (cliType == .claudeCode) ? (args["channel_enabled"]?.boolValue ?? false) : false
        let sdkEnabled = (cliType == .claudeCode) ? (args["sdk_enabled"]?.boolValue ?? false) : false
        let geminiStreamEnabled = (cliType == .gemini) ? (args["gemini_stream_enabled"]?.boolValue ?? false) : false
        let codexAppServerEnabled = (cliType == .codex) ? (args["codex_app_server_enabled"]?.boolValue ?? false) : false

        let config = Session.Config(
            name: args["name"]?.stringValue,
            workingDirectory: args["working_directory"]?.stringValue ?? AppConfig.shared.cwd(for: cliType),
            shell: AppConfig.shared.defaultShell,
            cliType: cliType,
            cliArgs: args["cli_args"]?.stringArrayValue ?? [],
            autoApprove: args["auto_approve"]?.boolValue ?? false,
            idleTimeout: AppConfig.shared.sessionIdleTimeout,
            env: nil,
            channelEnabled: channelEnabled,
            channelPort: args["channel_port"]?.intValue ?? 8787,
            channelServerName: args["channel_server_name"]?.stringValue ?? "openai-compat",
            sdkEnabled: sdkEnabled,
            sdkPort: args["sdk_port"]?.intValue ?? 8788,
            sdkModel: args["sdk_model"]?.stringValue,
            sdkPermissionMode: args["sdk_permission_mode"]?.stringValue ?? "acceptEdits",
            geminiStreamEnabled: geminiStreamEnabled,
            geminiStreamPort: args["gemini_stream_port"]?.intValue ?? 8789,
            codexAppServerEnabled: codexAppServerEnabled,
            codexAppServerPort: args["codex_app_server_port"]?.intValue ?? 8790
        )

        let session = try await sessionManager.createSession(config: config)

        var lines = [
            "세션 생성 완료.",
            "- session_id: \(session.id)",
            "- name: \(session.name)",
            "- status: \(session.status.rawValue)",
            "- cli_type: \(cliTypeStr)",
            "- working_directory: \(config.workingDirectory)",
        ]
        if channelEnabled, let url = session.channelServerURL {
            lines.append("- mode: 채널 서버")
            lines.append("- channel_url: \(url)/v1")
        } else if sdkEnabled, let url = session.sdkServerURL {
            lines.append("- mode: Agent SDK 브릿지")
            lines.append("- bridge_url: \(url)/v1")
        } else if geminiStreamEnabled, let url = session.geminiStreamServerURL {
            lines.append("- mode: Gemini Stream 브릿지")
            lines.append("- bridge_url: \(url)/v1")
        } else if codexAppServerEnabled, let url = session.codexAppServerURL {
            lines.append("- mode: Codex App Server 브릿지")
            lines.append("- bridge_url: \(url)/v1")
        } else {
            lines.append("- mode: PTY")
        }
        lines += [
            "",
            "세션이 ready 상태가 되면 session_send_message로 메시지를 보낼 수 있습니다.",
            "현재 상태를 확인하려면 session_get을 사용하세요.",
        ]
        return mcpTextResult(lines.joined(separator: "\n"))
    }

    private func toolSessionList() -> JSONValue {
        let sessions = sessionManager.listSessions()

        if sessions.isEmpty {
            return mcpTextResult("활성 세션이 없습니다. session_create로 새 세션을 만드세요.")
        }

        var lines = ["활성 세션 목록 (\(sessions.count)개):"]
        for s in sessions {
            var modeInfo = "PTY"
            if s.bridgeEnabled, let url = s.bridgeUrl { modeInfo = "브릿지 (\(url)/v1)" }
            else if s.channelEnabled, let url = s.channelUrl { modeInfo = "채널 (\(url)/v1)" }
            lines.append("- [\(s.id)] \(s.name) | status: \(s.status.rawValue) | cli: \(s.cliType) | mode: \(modeInfo) | dir: \(s.workingDirectory)")
        }

        return mcpTextResult(lines.joined(separator: "\n"))
    }

    private func toolSessionGet(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)

        var lines = [
            "세션 상세:",
            "- id: \(session.id)",
            "- name: \(session.name)",
            "- status: \(session.status.rawValue)",
            "- working_directory: \(session.config.workingDirectory)",
            "- cli_type: \(session.config.cliType.rawValue)",
            "- messages_sent: \(session.messageCount)",
            "- uptime: \(Int(Date().timeIntervalSince(session.createdAt)))초",
        ]

        // 모드 정보
        if let tunnelUrl = session.tunnelURL {
            lines.append("- tunnel_url: \(tunnelUrl)")
        }

        if session.isBridgeMode, let url = session.bridgeServerURL {
            lines.append("- mode: 브릿지")
            lines.append("- bridge_url: \(url)/v1")
        } else if session.isChannelMode, let url = session.channelServerURL {
            lines.append("- mode: 채널")
            lines.append("- channel_url: \(url)/v1")
        } else {
            lines.append("- mode: PTY")
        }

        if let pending = session.pendingApproval {
            lines.append("- pending_approval:")
            lines.append("  - id: \(pending.id)")
            lines.append("  - prompt: \(pending.prompt)")
        }

        return mcpTextResult(lines.joined(separator: "\n"))
    }

    private func toolSessionDelete(_ args: [String: JSONValue]) async throws -> JSONValue {
        let session = try resolveSession(args)

        await MainActor.run {
            sessionManager.deleteSession(id: session.id)
        }

        return mcpTextResult("세션 \(session.name) (\(session.id)) 삭제 완료.")
    }

    private func toolSessionRename(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)
        let newName = try requireString(args, "new_name")
        try sessionManager.renameSession(id: session.id, newName: newName)
        return mcpTextResult("세션 이름 변경 완료: '\(session.name)' → '\(newName)'")
    }

    private func toolSessionStop(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)
        sessionManager.stopSession(id: session.id)
        return mcpTextResult("세션 \(session.name) (\(session.id)) 중지 완료. session_start로 재시작할 수 있습니다.")
    }

    private func toolSessionStart(_ args: [String: JSONValue]) async throws -> JSONValue {
        let session = try resolveSession(args)
        guard session.status == .stopped || session.status == .error else {
            return mcpTextResult("세션 \(session.name)은 이미 \(session.status.rawValue) 상태입니다. 중지(stopped) 또는 오류(error) 상태인 세션만 재시작할 수 있습니다.")
        }
        try await sessionManager.startSession(id: session.id)
        return mcpTextResult("세션 \(session.name) (\(session.id)) 재시작 요청 완료. session_get으로 상태를 확인하세요.")
    }

    private func toolSessionSendMessage(_ args: [String: JSONValue]) async throws -> JSONValue {
        let session = try resolveSession(args)
        let text = try requireString(args, "text")
        let timeout = TimeInterval(args["timeout"]?.intValue ?? 300)

        if session.status == .stopped || session.status == .error {
            throw MCPError.sessionNotReady(session.id, "\(session.status.rawValue) — session_start로 재시작 후 시도하세요.")
        }
        guard session.status == .ready else {
            throw MCPError.sessionNotReady(session.id, session.status.rawValue)
        }

        let result = try await session.sendMessage(text: text, timeout: timeout)
        let responseText = result.response.result

        return mcpTextResult(responseText)
    }

    private func toolSessionInput(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)

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
        let session = try resolveSession(args)

        let raw = String(data: session.outputBuffer, encoding: .utf8) ?? ""
        let text = OutputParser.stripANSI(raw)

        return mcpTextResult(text.isEmpty ? "(출력 없음)" : text)
    }

    private func toolSessionApprove(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)
        let approvalId = try requireString(args, "approval_id")
        let approved = args["approved"]?.boolValue ?? true

        try session.respondToApproval(id: approvalId, approved: approved)

        return mcpTextResult(approved ? "승인 완료 (approval_id: \(approvalId))" : "거부 완료 (approval_id: \(approvalId))")
    }

    private func toolSessionPending(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)

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

    // MARK: - Tunnel Tools

    private func toolSessionTunnelStart(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)
        guard session.status != .terminated else {
            throw MCPError.sessionNotReady(session.id, "terminated")
        }
        sessionManager.startTunnel(sessionId: session.id)
        return mcpTextResult("""
        터널 시작 요청 완료. 연결에 수 초가 걸릴 수 있습니다.
        session_get(session_id: "\(session.name)")으로 tunnel_url을 확인하세요.
        """)
    }

    private func toolSessionTunnelStop(_ args: [String: JSONValue]) throws -> JSONValue {
        let session = try resolveSession(args)
        sessionManager.stopTunnel(sessionId: session.id)
        return mcpTextResult("세션 '\(session.name)' 터널 중지 완료.")
    }

    // MARK: - Config Tools

    private func toolConfigGet() async -> JSONValue {
        let cfg = await MainActor.run { AppConfig.shared }
        var lines = [
            "Consolent 설정:",
            "",
            "[API Server]",
            "- api_enabled: \(cfg.apiEnabled)",
            "- api_port: \(cfg.apiPort)",
            "- api_bind: \(cfg.apiBind)",
            "- include_raw_output: \(cfg.includeRawOutput)",
            "",
            "[Sessions]",
            "- max_concurrent_sessions: \(cfg.maxConcurrentSessions)",
            "- session_idle_timeout: \(cfg.sessionIdleTimeout)초",
            "- output_buffer_mb: \(cfg.outputBufferMB)",
            "",
            "[CLI Tool]",
            "- default_cli_type: \(cfg.defaultCliType.rawValue)",
            "- default_shell: \(cfg.defaultShell)",
            "- default_cwd: \(cfg.defaultCwd)",
        ]

        if !cfg.cwdPerCliType.isEmpty {
            lines.append("- cwd_per_cli_type:")
            for (k, v) in cfg.cwdPerCliType.sorted(by: { $0.key < $1.key }) {
                lines.append("    \(k): \(v)")
            }
        }

        lines += [
            "",
            "[Terminal]",
            "- font_family: \(cfg.fontFamily)",
            "- font_size: \(cfg.fontSize)",
            "- theme: \(cfg.theme)",
            "- scrollback_lines: \(cfg.scrollbackLines)",
            "- headless_terminal_rows: \(cfg.headlessTerminalRows)",
            "",
            "[App]",
            "- launch_to_menu_bar: \(cfg.launchToMenuBar)",
            "",
            "[Debug]",
            "- log_level: \(cfg.logLevel)",
            "- bridge_log_level: \(cfg.bridgeLogLevel) (error/info/debug)",
            "- debug_log_retention_days: \(cfg.debugLogRetentionDays)",
            "- debug_log_max_file_size_mb: \(cfg.debugLogMaxFileSizeMB)",
        ]

        return mcpTextResult(lines.joined(separator: "\n"))
    }

    private func toolConfigUpdate(_ args: [String: JSONValue]) async throws -> JSONValue {
        guard case .object(let settings)? = args["settings"] else {
            throw MCPError.invalidParameter("settings", "settings 객체가 필요합니다.")
        }

        var changed: [String] = []

        await MainActor.run {
            let cfg = AppConfig.shared

            for (key, value) in settings {
                switch key {
                case "log_level":
                    if let v = value.stringValue {
                        cfg.logLevel = v
                        changed.append("log_level → \(v)")
                    }
                case "default_cli_type":
                    if let v = value.stringValue, let cliType = CLIType(rawValue: v) {
                        cfg.defaultCliType = cliType
                        changed.append("default_cli_type → \(v)")
                    }
                case "default_shell":
                    if let v = value.stringValue {
                        cfg.defaultShell = v
                        changed.append("default_shell → \(v)")
                    }
                case "default_cwd":
                    if let v = value.stringValue {
                        cfg.defaultCwd = v
                        changed.append("default_cwd → \(v)")
                    }
                case "max_concurrent_sessions":
                    if let v = value.intValue {
                        cfg.maxConcurrentSessions = v
                        changed.append("max_concurrent_sessions → \(v)")
                    }
                case "session_idle_timeout":
                    if let v = value.intValue {
                        cfg.sessionIdleTimeout = v
                        changed.append("session_idle_timeout → \(v)")
                    }
                case "output_buffer_mb":
                    if let v = value.intValue {
                        cfg.outputBufferMB = v
                        changed.append("output_buffer_mb → \(v)")
                    }
                case "include_raw_output":
                    if let v = value.boolValue {
                        cfg.includeRawOutput = v
                        changed.append("include_raw_output → \(v)")
                    }
                case "font_family":
                    if let v = value.stringValue {
                        cfg.fontFamily = v
                        changed.append("font_family → \(v)")
                    }
                case "font_size":
                    if let v = value.intValue {
                        cfg.fontSize = v
                        changed.append("font_size → \(v)")
                    }
                case "theme":
                    if let v = value.stringValue {
                        cfg.theme = v
                        changed.append("theme → \(v)")
                    }
                case "scrollback_lines":
                    if let v = value.intValue {
                        cfg.scrollbackLines = v
                        changed.append("scrollback_lines → \(v)")
                    }
                case "headless_terminal_rows":
                    if let v = value.intValue {
                        cfg.headlessTerminalRows = v
                        changed.append("headless_terminal_rows → \(v)")
                    }
                case "launch_to_menu_bar":
                    if let v = value.boolValue {
                        cfg.launchToMenuBar = v
                        changed.append("launch_to_menu_bar → \(v)")
                    }
                case "debug_log_retention_days":
                    if let v = value.intValue {
                        cfg.debugLogRetentionDays = v
                        changed.append("debug_log_retention_days → \(v)")
                    }
                case "debug_log_max_file_size_mb":
                    if let v = value.intValue {
                        cfg.debugLogMaxFileSizeMB = v
                        changed.append("debug_log_max_file_size_mb → \(v)")
                    }
                case "bridge_log_level":
                    if let v = value.stringValue {
                        cfg.bridgeLogLevel = v
                        changed.append("bridge_log_level → \(v)")
                    }
                case "api_port":
                    if let v = value.intValue {
                        cfg.apiPort = v
                        changed.append("api_port → \(v) (⚠️ 앱 재시작 필요)")
                    }
                case "api_bind":
                    if let v = value.stringValue {
                        cfg.apiBind = v
                        changed.append("api_bind → \(v) (⚠️ 앱 재시작 필요)")
                    }
                default:
                    changed.append("⚠️ 알 수 없는 설정 키: \(key)")
                }
            }
        }

        if changed.isEmpty {
            return mcpTextResult("변경된 설정이 없습니다.")
        }

        return mcpTextResult("설정 변경 완료:\n" + changed.map { "- \($0)" }.joined(separator: "\n"))
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

    /// 세션을 이름 또는 ID로 찾는다. session_id 파라미터에 이름이나 ID 모두 사용 가능.
    /// 이름이 더 일반적이므로 이름을 먼저 시도하고, 없으면 ID로 폴백한다.
    private func resolveSession(_ args: [String: JSONValue], key: String = "session_id") throws -> Session {
        let value = try requireString(args, key)
        // 1. 이름으로 먼저 시도
        if let session = sessionManager.getSession(name: value) {
            return session
        }
        // 2. ID로 폴백
        if let session = sessionManager.getSession(id: value) {
            return session
        }
        throw MCPError.sessionNotFound(value)
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
