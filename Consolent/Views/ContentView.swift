import SwiftUI

/// 메인 윈도우. 사이드바(세션 목록) + 터미널 뷰 + 상태바.
struct ContentView: View {

    @ObservedObject var sessionManager = SessionManager.shared
    @ObservedObject var apiServer: APIServer
    @ObservedObject var config = AppConfig.shared

    @Environment(\.openSettings) private var openSettings

    @State private var showNewSession = false
    @State private var newSessionName = ""
    @State private var newSessionCwd = ""
    @State private var newSessionCliType: CLIType = .claudeCode
    @State private var newSessionAutoApprove = false

    /// 현재 이름이 CLI 기본값(claude-code, gemini, codex)이면 false → 타입 변경 시 자동 업데이트
    private var isSessionNameCustomized: Bool {
        let defaults = Set(CLIType.allCases.map { $0.rawValue })
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !defaults.contains(trimmed)
    }

    var body: some View {
        HSplitView {
            // ── 사이드바: 세션 목록 ──
            sidebar
                .frame(minWidth: 220, idealWidth: 250, maxWidth: 300)

            // ── 메인: 터미널 ──
            VStack(spacing: 0) {
                terminalArea
                statusBar
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .sheet(isPresented: $showNewSession) {
            newSessionSheet
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                Text("세션 목록")
                    .font(.headline)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: {
                    newSessionCliType = config.defaultCliType
                    newSessionName = config.defaultCliType.rawValue
                    newSessionCwd = config.defaultCwd
                    newSessionAutoApprove = false
                    showNewSession = true
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundColor(.accentColor)
                .help("New Session")
            }
            .padding(.horizontal, 16)
            .padding(.top, 20) // 윈도우 컨트롤(신호등 버튼) 공간 확보
            .padding(.bottom, 12)

            // 세션 리스트
            if sessionManager.sessions.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("열려있는 세션이 없습니다")
                        .foregroundColor(.secondary)
                        .font(.callout)
                    Spacer()
                }
            } else {
                List(selection: $sessionManager.selectedSessionId) {
                    ForEach(Array(sessionManager.sessions.values).sorted(by: { $0.createdAt < $1.createdAt })) { session in
                        SessionRow(session: session, onClose: {
                            sessionManager.deleteSession(id: session.id)
                        })
                        .tag(session.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
            }

            Spacer(minLength: 0)

            // 하단 상태 및 설정
            HStack(spacing: 12) {
                Button(action: {
                    openSettings()
                }) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
                .help("Settings")

                Spacer()

                // API 상태 표시
                HStack(spacing: 6) {
                    Circle()
                        .fill(apiServer.serverError != nil ? Color.red : (apiServer.isRunning ? Color.green : Color.gray))
                        .frame(width: 8, height: 8)
                        .shadow(color: apiServer.serverError != nil ? .red.opacity(0.5) : (apiServer.isRunning ? .green.opacity(0.5) : .clear), radius: 2)
                    Text(verbatim: "API :\(config.apiPort)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            .padding(.horizontal, 16)
            .frame(height: 44)
            .overlay(Divider(), alignment: .top)
        }
        .background(VisualEffectView(material: .sidebar, blendingMode: .behindWindow))
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
        HStack(spacing: 16) {
            if let session = sessionManager.selectedSession {
                statusBadge(session.status)
                
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundColor(.secondary)
                    Text(session.config.workingDirectory)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                HStack(spacing: 4) {
                    Image(systemName: "message")
                        .foregroundColor(.secondary)
                    Text("\(session.messageCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }

                if let approval = session.pendingApproval {
                    HStack(spacing: 8) {
                        Text("권한 요청됨")
                            .font(.caption)
                            .foregroundColor(.orange)
                            .fontWeight(.medium)
                            
                        Button(action: {
                            try? session.respondToApproval(id: approval.id, approved: true)
                        }) {
                            Text("승인")
                                .fontWeight(.medium)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)

                        Button("거절") {
                            try? session.respondToApproval(id: approval.id, approved: false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(.leading, 8)
                    .transition(.opacity)
                }
            } else {
                Text("선택된 세션 없음")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(VisualEffectView(material: .headerView, blendingMode: .withinWindow))
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Helpers

    private func statusBadge(_ status: Session.Status) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor(status))
                .frame(width: 8, height: 8)
                .shadow(color: statusColor(status).opacity(0.3), radius: 2)
            Text(status.rawValue.capitalized)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(statusColor(status))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(statusColor(status).opacity(0.15))
        .cornerRadius(6)
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
        VStack(spacing: 0) {
            // Sheet Header
            HStack {
                Image(systemName: "terminal.badge.plus")
                    .font(.title2)
                    .foregroundColor(.accentColor)
                Text("새 세션")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            Form {
                Section {
                    Picker("CLI 도구", selection: $newSessionCliType) {
                        ForEach(CLIType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: newSessionCliType) { _, newType in
                        // 이름이 CLI 기본값(claude-code/gemini/codex)이면 타입에 맞춰 자동 변경
                        if !isSessionNameCustomized {
                            newSessionName = newType.rawValue
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        TextField("세션 이름 (모델 ID)", text: $newSessionName)
                            .textFieldStyle(.roundedBorder)
                        if isNewSessionNameDuplicate {
                            Text("이미 사용 중인 이름입니다")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }

                    HStack {
                        TextField("작업 디렉토리", text: $newSessionCwd)
                            .textFieldStyle(.roundedBorder)

                        Button("찾아보기…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url {
                                newSessionCwd = url.path
                            }
                        }
                    }

                    Toggle(isOn: $newSessionAutoApprove) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("자동 승인")
                            Text("파일 수정이나 터미널 명령 실행 시 승인을 건너뜁니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, 8)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            // Bottom Actions
            HStack {
                Spacer()
                Button("취소") {
                    showNewSession = false
                }
                .keyboardShortcut(.cancelAction)

                Button("생성") {
                    showNewSession = false
                    Task {
                        let trimmedName = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
                        // 사용자가 커스텀 이름을 입력했으면 명시적 전달 (중복 시 에러).
                        // CLI 기본값이면 nil → SessionManager가 중복 시 자동 번호 부여.
                        let sessionName: String? = isSessionNameCustomized ? trimmedName : nil
                        let sessionConfig = Session.Config(
                            name: sessionName,
                            workingDirectory: newSessionCwd.isEmpty ? config.defaultCwd : newSessionCwd,
                            shell: config.defaultShell,
                            cliType: newSessionCliType,
                            autoApprove: newSessionAutoApprove
                        )
                        _ = try? await sessionManager.createSession(config: sessionConfig)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isNewSessionNameDuplicate)
            }
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .top)
        }
        .frame(width: 450, height: 420)
    }

    /// 세션 이름 중복 여부 (입력 중 실시간 체크)
    private var isNewSessionNameDuplicate: Bool {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return sessionManager.isNameTaken(name)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    @ObservedObject var session: Session
    var onClose: () -> Void
    @State private var isHovering = false
    @State private var showCloseAlert = false

    var body: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                        .shadow(color: statusColor.opacity(0.4), radius: 2)

                    Text(session.name)
                        .font(.system(.caption, design: .rounded))
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    // 이름이 CLI 타입과 다르면 타입 뱃지 표시
                    if session.name != session.config.cliType.rawValue {
                        Text(session.config.cliType.displayName)
                            .font(.system(.caption2))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(3)
                    }

                    Text(session.id)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help("더블 클릭하여 복사")
                        .onTapGesture(count: 2) {
                            let pasteboard = NSPasteboard.general
                            pasteboard.clearContents()
                            pasteboard.setString(session.id, forType: .string)
                        }

                    if session.status == .busy {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }

                Text(session.config.workingDirectory)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(session.config.workingDirectory)

                // Cloudflare 터널 상태/URL 표시
                cloudflareStatusView(session: session)
            }

            Spacer()

            if isHovering {
                Button(action: { showCloseAlert = true }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary.opacity(0.7))
                        .imageScale(.medium)
                }
                .buttonStyle(.plain)
                .help("Close Session")
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle()) // Makes the whole row hoverable
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
        .alert("세션 종료", isPresented: $showCloseAlert) {
            Button("취소", role: .cancel) {}
            Button("종료", role: .destructive) {
                onClose()
            }
        } message: {
            Text("세션을 종료하시겠습니까?\n이 작업은 실행중인 CLI 프로세스도 함께 종료합니다.")
        }
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

    @ViewBuilder
    private func cloudflareStatusView(session: Session) -> some View {
        switch session.cloudflare.tunnelState {
        case .idle:
            EmptyView()
        case .installing:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("cloudflared 설치 중...")
                    .font(.caption2)
                    .foregroundColor(.orange)
            }
        case .starting:
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("터널 연결 중...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        case .running(let url):
            HStack(spacing: 4) {
                Image(systemName: "globe")
                    .font(.caption2)
                    .foregroundColor(.blue)
                Text(url)
                    .font(.caption2)
                    .foregroundColor(.blue)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .onTapGesture {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
            }
            .help("Cloudflare 터널 URL — 클릭하여 복사")
        case .error(let msg):
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.red)
                Text("터널 오류: \(msg)")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Visual Effect Wrapper
/// A helper view to use NSVisualEffectView in SwiftUI.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
