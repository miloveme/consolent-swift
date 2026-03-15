import SwiftUI

// MARK: - User Guide

struct UserGuideView: View {

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                section("Overview") {
                    Text("""
                    Consolent is a macOS native terminal application that wraps Claude Code CLI \
                    with an HTTP/WebSocket API layer. Claude Code runs inside a real PTY \
                    (pseudo-terminal), and API calls inject input as if a human were typing. \
                    You can also interact with Claude Code directly through the built-in terminal UI.
                    """)
                }

                section("Getting Started") {
                    step("1", "Install Claude Code",
                         "Make sure the `claude` CLI is installed and available in your PATH, " +
                         "or set the path in Settings > Claude Code.")
                    step("2", "Create a Session",
                         "Click the + button in the sidebar or press Cmd+T. " +
                         "Choose a working directory and click Create.")
                    step("3", "Interact",
                         "Type directly in the terminal, or send messages through the API. " +
                         "Claude Code sees both as regular keyboard input.")
                }

                section("Keyboard Shortcuts") {
                    shortcutTable([
                        ("Cmd + T", "New Session"),
                        ("Cmd + W", "Close Session"),
                        ("Cmd + Shift + ]", "Next Session"),
                        ("Cmd + Shift + [", "Previous Session"),
                        ("Cmd + ,", "Settings"),
                    ])
                }

                section("Session States") {
                    stateRow("initializing", "circle.dotted", .gray,
                             "Claude Code is starting up")
                    stateRow("ready", "circle.fill", .green,
                             "Waiting for input (prompt detected)")
                    stateRow("busy", "circle.fill", .orange,
                             "Processing a message")
                    stateRow("waiting_approval", "exclamationmark.circle.fill", .yellow,
                             "Claude Code is asking for permission (Y/n)")
                    stateRow("error", "xmark.circle.fill", .red,
                             "An error occurred")
                    stateRow("terminated", "circle.slash", .gray,
                             "Session has ended")
                }

                section("Approval Handling") {
                    Text("""
                    When Claude Code asks for permission (e.g. to edit a file), Consolent \
                    detects the approval prompt. You can approve or deny it via:
                    """)
                    bullet("The Approve / Deny buttons in the status bar")
                    bullet("The API endpoint POST /sessions/:id/approve/:approvalId")
                    bullet("The WebSocket stream with type \"approve\"")
                    bullet("Auto-approve mode (set per-session at creation time)")
                }

                section("Settings") {
                    Text("""
                    Open Settings (Cmd + ,) to configure the API server port, authentication key, \
                    default working directory, terminal font, and other options. \
                    Configuration is saved to ~/Library/Application Support/Consolent/config.json.
                    """)
                }

                Spacer(minLength: 20)
            }
            .padding(32)
        }
        .frame(minWidth: 600, idealWidth: 700, minHeight: 500, idealHeight: 650)
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Consolent User Guide")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("Claude Code Terminal with API Control")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            content()
        }
    }

    private func step(_ number: String, _ title: String, _ desc: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(.title3, design: .rounded))
                .fontWeight(.bold)
                .foregroundColor(.accentColor)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                Text(desc).foregroundColor(.secondary).font(.callout)
            }
        }
    }

    private func shortcutTable(_ items: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(items, id: \.0) { key, action in
                HStack {
                    Text(key)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 180, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(4)
                    Text(action)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func stateRow(_ name: String, _ icon: String, _ color: Color, _ desc: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)
            Text(name)
                .font(.system(.body, design: .monospaced))
                .frame(width: 140, alignment: .leading)
            Text(desc)
                .foregroundColor(.secondary)
                .font(.callout)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\u{2022}").foregroundColor(.secondary)
            Text(text).font(.callout)
        }
        .padding(.leading, 4)
    }
}

// MARK: - API Reference

struct APIReferenceView: View {

    @ObservedObject var config: AppConfig

    private let tocItems: [(id: String, icon: String, title: String)] = [
        ("toc-connection",  "link",              "Connection"),
        ("toc-openai",      "arrow.left.arrow.right", "OpenAI Compatible"),
        ("toc-sessions",    "rectangle.stack",   "Sessions"),
        ("toc-messages",    "message",           "Messages"),
        ("toc-input",       "keyboard",          "Raw Input"),
        ("toc-output",      "text.alignleft",    "Output"),
        ("toc-approval",    "checkmark.shield",  "Approval"),
        ("toc-websocket",   "bolt.horizontal",   "WebSocket Streaming"),
        ("toc-curl",        "terminal",          "Quick Start (curl)"),
    ]

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header

                // 목차
                tableOfContents(proxy: proxy)

                connectionInfo
                    .id("toc-connection")

                endpointSection("OpenAI Compatible") {
                    endpoint("POST", "/v1/chat/completions", "Send a chat completion request (OpenAI SDK compatible)",
                             request: """
                             {
                               "model": "claude-code",
                               "messages": [{"role": "user", "content": "Hello"}],
                               "stream": false,
                               "timeout": 300
                             }
                             """,
                             response: """
                             {
                               "id": "chatcmpl-m_x1y2z3",
                               "object": "chat.completion",
                               "created": 1710460800,
                               "model": "claude-code",
                               "choices": [{
                                 "index": 0,
                                 "message": {"role": "assistant", "content": "..."},
                                 "finish_reason": "stop"
                               }],
                               "usage": {"prompt_tokens": 0, "completion_tokens": 0, "total_tokens": 0}
                             }
                             """,
                             notes: "Accepts temperature, max_tokens, top_p, etc. for compatibility but ignores them. When stream=true, returns SSE chunks. Usage tokens are always 0.")

                    endpoint("GET", "/v1/models", "List available models",
                             response: """
                             {
                               "object": "list",
                               "data": [
                                 {"id": "claude-code", "object": "model", "owned_by": "consolent"},
                                 {"id": "codex", "object": "model", "owned_by": "consolent"},
                                 {"id": "gemini", "object": "model", "owned_by": "consolent"}
                               ]
                             }
                             """,
                             notes: "Models are dynamically generated from registered CLI adapters.")
                }
                .id("toc-openai")

                endpointSection("Sessions") {
                    endpoint("POST", "/sessions", "Create a new Claude Code session",
                             request: """
                             {
                               "working_directory": "/path/to/project",
                               "shell": "/bin/zsh",
                               "claude_args": ["--verbose"],
                               "auto_approve": false,
                               "idle_timeout": 3600,
                               "env": {"KEY": "value"}
                             }
                             """,
                             response: """
                             {
                               "session_id": "s_a1b2c3d4",
                               "status": "initializing",
                               "created_at": "2025-01-01T00:00:00Z"
                             }
                             """,
                             notes: "All fields are optional. Defaults come from app settings.")

                    endpoint("GET", "/sessions", "List all active sessions",
                             response: """
                             {
                               "sessions": [
                                 {
                                   "id": "s_a1b2c3d4",
                                   "status": "ready",
                                   "working_directory": "/path",
                                   "created_at": "...",
                                   "last_activity": "...",
                                   "message_count": 5
                                 }
                               ]
                             }
                             """)

                    endpoint("GET", "/sessions/:id", "Get session details",
                             response: """
                             {
                               "id": "s_a1b2c3d4",
                               "status": "ready",
                               "working_directory": "/path",
                               "pending_approval": null,
                               "stats": {
                                 "messages_sent": 5,
                                 "uptime_seconds": 120
                               }
                             }
                             """)

                    endpoint("DELETE", "/sessions/:id", "Terminate and remove a session",
                             notes: "Returns 204 No Content on success.")
                }
                .id("toc-sessions")

                endpointSection("Messages") {
                    endpoint("POST", "/sessions/:id/message", "Send a message and wait for response",
                             request: """
                             {
                               "text": "Explain this codebase",
                               "timeout": 300
                             }
                             """,
                             response: """
                             {
                               "message_id": "m_e5f6g7h8",
                               "response": {
                                 "text": "This project is...",
                                 "raw": "\\u001b[1mThis project is...\\u001b[0m",
                                 "files_changed": ["src/main.ts"],
                                 "duration_ms": 4500
                               }
                             }
                             """,
                             notes: "This is a synchronous endpoint. It blocks until Claude responds or the timeout is reached. Default timeout: 300s.")
                }
                .id("toc-messages")

                endpointSection("Raw Input") {
                    endpoint("POST", "/sessions/:id/input", "Inject raw text or key sequences",
                             request: """
                             { "text": "hello world\\n" }
                             // or
                             { "keys": ["ctrl+c"] }
                             """,
                             notes: "Supported keys: ctrl+c, ctrl+d, ctrl+z, ctrl+l, enter, tab, escape, up, down, left, right. Raw text is injected as-is (include \\n for Enter).")
                }
                .id("toc-input")

                endpointSection("Output") {
                    endpoint("GET", "/sessions/:id/output", "Read the output buffer",
                             response: """
                             {
                               "text": "clean text without ANSI",
                               "raw": "\\u001b[32mraw output\\u001b[0m",
                               "offset": 1024,
                               "total_bytes": 1024
                             }
                             """)
                }
                .id("toc-output")

                endpointSection("Approval") {
                    endpoint("GET", "/sessions/:id/pending", "Check for pending approval prompts",
                             response: """
                             {
                               "pending": {
                                 "id": "a_x1y2z3w4",
                                 "prompt": "Allow edit to main.ts? (y/n)",
                                 "detected_at": "2025-01-01T00:00:00Z"
                               }
                             }
                             """,
                             notes: "\"pending\" is null when no approval is waiting.")

                    endpoint("POST", "/sessions/:id/approve/:approvalId", "Respond to an approval",
                             request: """
                             { "approved": true }
                             """)
                }
                .id("toc-approval")

                endpointSection("WebSocket Streaming") {
                    wsInfo
                }
                .id("toc-websocket")

                curlExamples
                    .id("toc-curl")

                Spacer(minLength: 20)
            }
            .padding(32)
        }
        } // ScrollViewReader
        .frame(minWidth: 650, idealWidth: 750, minHeight: 500, idealHeight: 700)
    }

    // MARK: - Components

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .font(.system(size: 32))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Consolent API Reference")
                        .font(.title)
                        .fontWeight(.bold)
                    Text("HTTP & WebSocket API Documentation")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
        }
    }

    private func tableOfContents(proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Table of Contents")
                .font(.title3)
                .fontWeight(.semibold)

            LazyVGrid(columns: [
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
                GridItem(.flexible(), alignment: .leading),
            ], spacing: 6) {
                ForEach(tocItems, id: \.id) { item in
                    Button {
                        withAnimation {
                            proxy.scrollTo(item.id, anchor: .top)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                                .frame(width: 16)
                                .foregroundColor(.accentColor)
                            Text(item.title)
                                .font(.callout)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        if hovering {
                            NSCursor.pointingHand.push()
                        } else {
                            NSCursor.pop()
                        }
                    }
                }
            }
            .padding(12)
            .background(Color.secondary.opacity(0.06))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
            )
        }
    }

    private var connectionInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connection")
                .font(.title2)
                .fontWeight(.semibold)

            infoRow("Base URL", "http://\(config.apiBind):\(config.apiPort)")
            infoRow("Auth", "Bearer token in Authorization header")

            VStack(alignment: .leading, spacing: 4) {
                Text("Your API Key:")
                    .font(.callout)
                    .foregroundColor(.secondary)
                HStack {
                    Text(config.apiKey)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .background(Color.secondary.opacity(0.1))
                        .cornerRadius(6)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(config.apiKey, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy API Key")
                }
            }

            codeBlock("""
            # Authentication header
            Authorization: Bearer \(config.apiKey)
            """)
        }
    }

    private func endpointSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
            content()
        }
    }

    private func endpoint(
        _ method: String,
        _ path: String,
        _ desc: String,
        request: String? = nil,
        response: String? = nil,
        notes: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(method)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(methodColor(method))
                    .cornerRadius(4)
                Text(path)
                    .font(.system(.body, design: .monospaced))
            }

            Text(desc)
                .foregroundColor(.secondary)
                .font(.callout)

            if let notes {
                Text(notes)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.leading, 4)
            }

            if let request {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Request Body")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    codeBlock(request)
                }
            }

            if let response {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Response")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    codeBlock(response)
                }
            }

            Divider().padding(.top, 4)
        }
        .padding(.leading, 8)
    }

    private var wsInfo: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("WS")
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.purple)
                    .cornerRadius(4)
                Text("/sessions/:id/stream?token=<API_KEY>")
                    .font(.system(.body, design: .monospaced))
            }

            Text("Real-time bidirectional streaming of terminal output and input.")
                .foregroundColor(.secondary)
                .font(.callout)

            VStack(alignment: .leading, spacing: 3) {
                Text("Server sends (output)")
                    .font(.caption).foregroundColor(.secondary)
                codeBlock("""
                {"type": "output", "text": "Claude's response..."}
                """)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Client sends (input)")
                    .font(.caption).foregroundColor(.secondary)
                codeBlock("""
                {"type": "input", "text": "explain this code"}
                """)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Client sends (approve)")
                    .font(.caption).foregroundColor(.secondary)
                codeBlock("""
                {"type": "approve", "id": "a_x1y2z3w4", "approved": true}
                """)
            }

            Text("Auth is via the token query parameter (not the Authorization header).")
                .font(.caption)
                .foregroundColor(.orange)
                .padding(.leading, 4)
        }
        .padding(.leading, 8)
    }

    private var curlExamples: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Start (curl)")
                .font(.title2)
                .fontWeight(.semibold)

            codeBlock("""
            # Create a session
            curl -X POST http://\(config.apiBind):\(config.apiPort)/sessions \\
              -H "Authorization: Bearer \(config.apiKey)" \\
              -H "Content-Type: application/json" \\
              -d '{"working_directory": "'\(config.defaultCwd)'"}'

            # Send a message (blocks until response)
            curl -X POST http://\(config.apiBind):\(config.apiPort)/sessions/SESSION_ID/message \\
              -H "Authorization: Bearer \(config.apiKey)" \\
              -H "Content-Type: application/json" \\
              -d '{"text": "What files are in this directory?"}'

            # Stream output via WebSocket (using websocat)
            websocat "ws://\(config.apiBind):\(config.apiPort)/sessions/SESSION_ID/stream?token=\(config.apiKey)"
            """)
        }
    }

    // MARK: - Helpers

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(label + ":")
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func codeBlock(_ code: String) -> some View {
        Text(code)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .cornerRadius(6)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
    }

    private func methodColor(_ method: String) -> Color {
        switch method {
        case "GET": return .blue
        case "POST": return .green
        case "DELETE": return .red
        case "PUT", "PATCH": return .orange
        default: return .gray
        }
    }
}

// MARK: - Previews

#Preview("User Guide") {
    UserGuideView()
}

#Preview("API Reference") {
    APIReferenceView(config: AppConfig())
}
