import SwiftUI

/// 메인 윈도우. 사이드바(세션 목록) + 터미널 뷰 + 상태바.
struct ContentView: View {

    @ObservedObject var sessionManager = SessionManager.shared
    @ObservedObject var apiServer: APIServer
    @ObservedObject var config = AppConfig.shared

    @State private var showSettings = false
    @State private var showNewSession = false
    @State private var newSessionCwd = ""
    @State private var newSessionCliType: CLIType = .claudeCode
    @State private var newSessionAutoApprove = false

    var body: some View {
        HSplitView {
            // ── 사이드바: 세션 목록 ──
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 300)

            // ── 메인: 터미널 ──
            VStack(spacing: 0) {
                terminalArea
                statusBar
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showSettings) {
            SettingsView(config: config, apiServer: apiServer)
        }
        .sheet(isPresented: $showNewSession) {
            newSessionSheet
        }
        .onAppear {
            newSessionCwd = config.defaultCwd
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                Text("Sessions")
                    .font(.headline)
                Spacer()
                Button(action: { showNewSession = true }) {
                    Image(systemName: "plus")
                }
                .buttonStyle(.plain)
                .help("New Session")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            // 세션 리스트
            if sessionManager.sessions.isEmpty {
                VStack {
                    Spacer()
                    Text("No sessions")
                        .foregroundColor(.secondary)
                        .font(.caption)
                    Spacer()
                }
            } else {
                List(selection: $sessionManager.selectedSessionId) {
                    ForEach(Array(sessionManager.sessions.values).sorted(by: { $0.createdAt < $1.createdAt })) { session in
                        SessionRow(session: session)
                            .tag(session.id)
                            .contextMenu {
                                Button("Close Session") {
                                    sessionManager.deleteSession(id: session.id)
                                }
                            }
                    }
                }
                .listStyle(.sidebar)
            }

            Divider()

            // 하단 버튼들
            HStack {
                Button(action: { showSettings = true }) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.plain)
                .help("Settings")

                Spacer()

                // API 상태 표시
                HStack(spacing: 4) {
                    Circle()
                        .fill(apiServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(verbatim: "API :\(config.apiPort)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    // MARK: - Terminal Area

    @ViewBuilder
    private var terminalArea: some View {
        if let session = sessionManager.selectedSession {
            TerminalViewWrapper(session: session)
                .id(session.id)  // 세션 변경 시 뷰 재생성
        } else {
            EmptyTerminalView()
        }
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack {
            if let session = sessionManager.selectedSession {
                statusBadge(session.status)
                Text(session.config.workingDirectory)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Text("Messages: \(session.messageCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if session.pendingApproval != nil {
                    Button("Approve") {
                        if let approval = session.pendingApproval {
                            try? session.respondToApproval(id: approval.id, approved: true)
                        }
                    }
                    .controlSize(.small)

                    Button("Deny") {
                        if let approval = session.pendingApproval {
                            try? session.respondToApproval(id: approval.id, approved: false)
                        }
                    }
                    .controlSize(.small)
                }
            } else {
                Text("No session selected")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Helpers

    private func statusBadge(_ status: Session.Status) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
            Text(status.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(statusColor(status).opacity(0.1))
        .cornerRadius(4)
    }

    private func statusColor(_ status: Session.Status) -> Color {
        switch status {
        case .ready: return .green
        case .busy: return .blue
        case .waitingApproval: return .orange
        case .initializing: return .yellow
        case .error: return .red
        case .terminated: return .gray
        }
    }

    // MARK: - New Session Sheet

    private var newSessionSheet: some View {
        VStack(spacing: 16) {
            Text("New Session")
                .font(.headline)

            HStack {
                Text("CLI Tool:")
                    .frame(width: 120, alignment: .trailing)
                Picker("", selection: $newSessionCliType) {
                    ForEach(CLIType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }

            HStack {
                Text("Working Directory:")
                    .frame(width: 120, alignment: .trailing)
                TextField("Path", text: $newSessionCwd)
                    .textFieldStyle(.roundedBorder)
                Button("Browse") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        newSessionCwd = url.path
                    }
                }
            }

            Toggle("자동 승인 (파일 생성/명령 실행 시 승인 건너뜀)", isOn: $newSessionAutoApprove)

            HStack {
                Spacer()
                Button("Cancel") {
                    showNewSession = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create") {
                    showNewSession = false
                    Task {
                        let sessionConfig = Session.Config(
                            workingDirectory: newSessionCwd.isEmpty ? config.defaultCwd : newSessionCwd,
                            shell: config.defaultShell,
                            cliType: newSessionCliType,
                            autoApprove: newSessionAutoApprove
                        )
                        _ = try? await sessionManager.createSession(config: sessionConfig)
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    @ObservedObject var session: Session

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(session.config.cliType.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.15))
                    .cornerRadius(3)
                Text(session.id)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1)
            }

            Text(session.config.workingDirectory)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        switch session.status {
        case .ready: return .green
        case .busy: return .blue
        case .waitingApproval: return .orange
        case .initializing: return .yellow
        case .error: return .red
        case .terminated: return .gray
        }
    }
}
