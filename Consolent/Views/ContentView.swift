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
    @State private var newSessionAutoApprove = true
    @State private var newSessionChannelEnabled = false
    @State private var newSessionChannelPort = 8787
    @State private var newSessionChannelServerName = "openai-compat"
    @State private var channelConfigFound = false
    @State private var channelConfigError = ""
    @State private var channelConfigInstalled = false  // Install 완료 후 Undo 표시용
    @State private var channelConfigApiKeyMissing = false  // API 키 미설정
    // SDK 모드
    @State private var newSessionSDKEnabled = false
    @State private var newSessionSDKPort = 8788
    @State private var newSessionSDKModel = ""
    @State private var newSessionSDKPermissionMode = "acceptEdits"
    // Gemini stream-json 모드
    @State private var newSessionGeminiStreamEnabled = false
    @State private var newSessionGeminiStreamPort = 8789
    // Codex app-server 모드
    @State private var newSessionCodexAppServerEnabled = false
    @State private var newSessionCodexAppServerPort = 8790
    @State private var windowVisible = true  // 윈도우 가시성 (TerminalView 활성화 제어)

    /// 현재 이름이 CLI 기본값(claude-code, gemini, codex)이면 false → 타입 변경 시 자동 업데이트
    private var isSessionNameCustomized: Bool {
        let defaults = Set(CLIType.allCases.map { $0.rawValue })
        let trimmed = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !defaults.contains(trimmed)
    }

    var body: some View {
        ZStack {
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

        // 전체 세션 복원 프로그레스 오버레이
        if sessionManager.isRestoring {
            restoringOverlay
        }
        } // ZStack
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.windowVisibilityChanged)) { notification in
            if let visible = notification.object as? Bool {
                windowVisible = visible
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.showNewSessionRequested)) { _ in
            showNewSession = true
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openSettingsRequested)) { notification in
            openSettings()
        }
        .sheet(isPresented: $showNewSession) {
            newSessionSheet
                .onAppear {
                    // 시트가 표시된 후 초기값 설정 (SwiftUI Picker 타이밍 이슈 방지)
                    newSessionCliType = config.defaultCliType
                    newSessionName = config.defaultCliType.rawValue
                    newSessionCwd = config.cwd(for: config.defaultCliType)
                    newSessionAutoApprove = true
                    newSessionChannelEnabled = false
                    newSessionChannelPort = 8787
                    newSessionChannelServerName = "openai-compat"
                    channelConfigFound = false
                    channelConfigError = ""
                    channelConfigInstalled = false
                    channelConfigApiKeyMissing = false
                }
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
                    ForEach(sessionManager.sessionOrder, id: \.self) { id in
                        if let session = sessionManager.sessions[id] {
                            SessionRow(session: session, onClose: {
                                sessionManager.deleteSession(id: session.id)
                            }, onStop: {
                                sessionManager.stopSession(id: session.id)
                            }, onStart: {
                                Task { try? await sessionManager.startSession(id: session.id) }
                            })
                            .tag(session.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        }
                    }
                    .onMove { from, to in
                        sessionManager.moveSession(from: from, to: to)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .disabled(sessionManager.isRestoringChannelSessions)
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

                // API 상태 표시 (클릭 시 설정 창 이동)
                Button(action: {
                    openSettings()
                    // 서버 탭(tag 1)으로 이동 요청
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NotificationCenter.default.post(name: AppDelegate.openSettingsRequested, object: 1)
                    }
                }) {
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
                .buttonStyle(.plain)
                .help("서버 설정 열기")
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
            VStack(spacing: 0) {
                // 포트 충돌 배너 (브릿지 세션)
                if let conflict = session.portConflict {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                            Text("포트 \(conflict.port) 충돌")
                                .fontWeight(.semibold)
                        }
                        Text("\"\(conflict.displayName)\"이(가) 포트 \(conflict.port)를 사용 중입니다.")
                            .font(.callout)
                        if !conflict.displayCommand.isEmpty {
                            Text(conflict.displayCommand)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        HStack(spacing: 10) {
                            Button("강제 종료 후 재시작") {
                                Task { try? await session.resolvePortConflictAndRestart() }
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                        }
                    }
                    .padding()
                    .background(Color.orange.opacity(0.1))
                    .cornerRadius(8)
                    .padding()
                }

                if session.isSDKMode || session.isGeminiStreamMode || session.isCodexAppServerMode {
                    SDKTerminalView(session: session)
                        .id(session.id)
                } else if windowVisible {
                    TerminalViewWrapper(session: session)
                        .id(session.id)  // 세션 변경 시 뷰 재생성
                } else {
                    // 윈도우 숨김 시 TerminalView 비활성화 (headless만 동작)
                    EmptyTerminalView()
                }
            }
        } else {
            EmptyTerminalView()
        }
    }

    // MARK: - Restoring Progress Overlay

    private var restoringOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ProgressView()
                    .scaleEffect(1.2)

                VStack(spacing: 6) {
                    Text("세션 복원 중...")
                        .font(.headline)
                    Text("\(sessionManager.restoringCurrent) / \(sessionManager.restoringTotal) 완료")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                ProgressView(value: Double(sessionManager.restoringCurrent),
                             total: Double(max(sessionManager.restoringTotal, 1)))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .frame(width: 240)
            }
            .padding(32)
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .shadow(color: .black.opacity(0.2), radius: 20)
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.25), value: sessionManager.isRestoring)
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

                if session.isChannelMode, let channelUrl = session.channelServerURL {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal")
                            .foregroundColor(.purple)
                        Text(channelUrl)
                            .font(.caption)
                            .foregroundColor(.purple)
                            .lineLimit(1)
                    }
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
        case .stopped: return .secondary
        case .error: return .red
        case .terminated: return .gray
        }
    }

    // MARK: - New Session Sheet

    private var newSessionSheet: some View {
        VStack(spacing: 0) {
            // Sheet Header
            HStack {
                Image(systemName: "terminal")
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
                        // 작업 디렉토리도 CLI 타입별 설정으로 변경
                        newSessionCwd = config.cwd(for: newType)
                        // 채널/SDK 서버는 Claude Code 전용; Gemini/Codex 브릿지도 초기화
                        if newType != .claudeCode {
                            newSessionChannelEnabled = false
                            newSessionSDKEnabled = false
                        }
                        if newType != .gemini { newSessionGeminiStreamEnabled = false }
                        if newType != .codex { newSessionCodexAppServerEnabled = false }
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

                    // 채널 서버 설정 (Claude Code 전용)
                    if newSessionCliType == .claudeCode {
                        Toggle(isOn: $newSessionChannelEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Channel Server")
                                Text("MCP 채널 서버 활성화 — API 요청이 채널 서버로 직접 전달됩니다.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: newSessionChannelEnabled) { _, enabled in
                            if enabled {
                                newSessionSDKEnabled = false  // 상호 배타
                                detectChannelConfig()
                            } else {
                                channelConfigFound = false
                                channelConfigError = ""
                                channelConfigApiKeyMissing = false
                            }
                        }

                        if newSessionChannelEnabled {
                            Text("WARNING: Loading development channels")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.red)

                            if channelConfigFound {
                                // 설정 감지 성공
                                HStack {
                                    Text("서버 이름")
                                    Spacer()
                                    Text(newSessionChannelServerName)
                                        .foregroundColor(.secondary)
                                }

                                HStack {
                                    Text("채널 포트")
                                    Spacer()
                                    Text(String(newSessionChannelPort))
                                        .foregroundColor(.secondary)
                                }

                                HStack {
                                    Label("~/.claude.json에서 설정을 자동으로 감지했습니다.",
                                          systemImage: "checkmark.circle")
                                        .font(.caption)
                                        .foregroundColor(.green)

                                    Spacer()

                                    if channelConfigInstalled {
                                        Button(action: { undoChannelConfig() }) {
                                            Label("Undo", systemImage: "arrow.uturn.backward")
                                        }
                                        .controlSize(.small)
                                    }
                                }

                                // API 키 미설정 경고
                                if channelConfigApiKeyMissing {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Label("OPENAI_COMPAT_API_KEY가 설정되지 않았습니다.",
                                              systemImage: "key")
                                            .font(.caption)
                                            .foregroundColor(.orange)

                                        HStack {
                                            Text(AppConfig.shared.apiKey)
                                                .font(.system(.caption, design: .monospaced))
                                                .foregroundColor(.secondary)
                                                .textSelection(.enabled)

                                            Spacer()

                                            Button(action: { applyChannelApiKey() }) {
                                                Label("API key 적용", systemImage: "key.fill")
                                            }
                                            .controlSize(.small)
                                        }
                                    }
                                }
                            } else {
                                // 설정 없음 — 에러 메시지 + Install 버튼
                                VStack(alignment: .leading, spacing: 6) {
                                    Label(channelConfigError, systemImage: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundColor(.red)

                                    Text("~/.claude.json mcpServers에 아래 설정이 필요합니다:")
                                        .font(.caption)
                                        .foregroundColor(.secondary)

                                    Text("""
                                    "\(newSessionChannelServerName)": {
                                      "command": "npx",
                                      "args": ["-y", "@miloveme/claude-code-api@latest"]
                                    }
                                    """)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.orange)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.orange.opacity(0.08))
                                    .cornerRadius(6)

                                    Button(action: { installChannelConfig() }) {
                                        Label("Install", systemImage: "square.and.arrow.down")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }

                    // SDK 모드 설정 (Claude Code 전용)
                    if newSessionCliType == .claudeCode {
                        Toggle(isOn: $newSessionSDKEnabled) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Agent Mode")
                                Text("Agent SDK 기반 — PTY 파싱 없이 안정적인 OpenAI 호환 API를 제공합니다.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .onChange(of: newSessionSDKEnabled) { _, enabled in
                            // SDK와 Channel은 상호 배타
                            if enabled {
                                newSessionChannelEnabled = false
                            }
                        }

                        if newSessionSDKEnabled {
                            HStack {
                                Text("Agent 포트")
                                Spacer()
                                TextField("", text: Binding(
                                    get: { String(newSessionSDKPort) },
                                    set: { if let v = Int($0) { newSessionSDKPort = v } }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                            }

                            LabeledContent("모델") {
                                Picker("", selection: $newSessionSDKModel) {
                                    Text("기본값").tag("")
                                    Section("Claude") {
                                        Text("claude-sonnet-4-20250514").tag("claude-sonnet-4-20250514")
                                        Text("claude-opus-4-20250514").tag("claude-opus-4-20250514")
                                        Text("claude-haiku-4-20250514").tag("claude-haiku-4-20250514")
                                    }
                                }
                                .pickerStyle(.menu)
                            }

                            LabeledContent("Permission") {
                                Picker("", selection: $newSessionSDKPermissionMode) {
                                    Text("Accept Edits").tag("acceptEdits")
                                    Text("Default").tag("default")
                                    Text("Bypass").tag("bypassPermissions")
                                }
                                .pickerStyle(.menu)
                                .frame(width: 150)
                            }

                            // venv 경로 + 상태
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text("Python 환경")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    if sdkVenvReady {
                                        Label("설치됨", systemImage: "checkmark.circle.fill")
                                            .font(.caption)
                                            .foregroundColor(.green)
                                    } else {
                                        Label("첫 실행 시 자동 설치", systemImage: "arrow.down.circle")
                                            .font(.caption)
                                            .foregroundColor(.orange)
                                    }
                                }

                                HStack(spacing: 4) {
                                    TextField("venv 경로", text: $config.sdkVenvPath)
                                        .textFieldStyle(.roundedBorder)
                                        .font(.caption)

                                    Button {
                                        let panel = NSOpenPanel()
                                        panel.canChooseDirectories = true
                                        panel.canChooseFiles = false
                                        panel.allowsMultipleSelection = false
                                        panel.prompt = "선택"
                                        if panel.runModal() == .OK, let url = panel.url {
                                            config.sdkVenvPath = url.path
                                        }
                                    } label: {
                                        Image(systemName: "folder")
                                    }
                                    .controlSize(.small)

                                    if config.sdkVenvPath != AppConfig.defaultSDKVenvPath {
                                        Button {
                                            config.sdkVenvPath = AppConfig.defaultSDKVenvPath
                                        } label: {
                                            Image(systemName: "arrow.counterclockwise")
                                        }
                                        .controlSize(.small)
                                        .help("기본 경로로 복원")
                                    }
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }

                // Gemini stream-json 모드 (Gemini CLI 전용)
                if newSessionCliType == .gemini {
                    Toggle(isOn: $newSessionGeminiStreamEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Stream JSON Mode")
                            Text("PTY 파싱 없이 --output-format stream-json으로 안정적인 API를 제공합니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if newSessionGeminiStreamEnabled {
                        HStack {
                            Text("브릿지 포트")
                            Spacer()
                            TextField("", text: Binding(
                                get: { String(newSessionGeminiStreamPort) },
                                set: { if let v = Int($0) { newSessionGeminiStreamPort = v } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        }
                    }
                }

                // Codex app-server 모드 (Codex CLI 전용)
                if newSessionCliType == .codex {
                    Toggle(isOn: $newSessionCodexAppServerEnabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("App Server Mode")
                            Text("PTY 파싱 없이 app-server --listen stdio://로 안정적인 API를 제공합니다.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    if newSessionCodexAppServerEnabled {
                        HStack {
                            Text("브릿지 포트")
                            Spacer()
                            TextField("", text: Binding(
                                get: { String(newSessionCodexAppServerPort) },
                                set: { if let v = Int($0) { newSessionCodexAppServerPort = v } }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
            .formStyle(.grouped)

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
                            autoApprove: newSessionAutoApprove,
                            channelEnabled: newSessionCliType == .claudeCode ? newSessionChannelEnabled : false,
                            channelPort: newSessionChannelPort,
                            channelServerName: newSessionChannelServerName,
                            sdkEnabled: newSessionCliType == .claudeCode ? newSessionSDKEnabled : false,
                            sdkPort: newSessionSDKPort,
                            sdkModel: newSessionSDKModel.isEmpty ? nil : newSessionSDKModel,
                            sdkPermissionMode: newSessionSDKPermissionMode,
                            geminiStreamEnabled: newSessionCliType == .gemini ? newSessionGeminiStreamEnabled : false,
                            geminiStreamPort: newSessionGeminiStreamPort,
                            codexAppServerEnabled: newSessionCliType == .codex ? newSessionCodexAppServerEnabled : false,
                            codexAppServerPort: newSessionCodexAppServerPort
                        )
                        _ = try? await sessionManager.createSession(config: sessionConfig)
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(isNewSessionNameDuplicate || (newSessionChannelEnabled && !channelConfigFound))
            }
            .padding(24)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(Divider(), alignment: .top)
        }
        .frame(width: 450, height: newSessionChannelEnabled ? 580 : (newSessionSDKEnabled || newSessionGeminiStreamEnabled || newSessionCodexAppServerEnabled) ? 520 : 480)
    }

    /// SDK venv가 설치되어 있는지 확인
    private var sdkVenvReady: Bool {
        let pythonPath = (config.sdkVenvPath as NSString).appendingPathComponent("bin/python3")
        return FileManager.default.isExecutableFile(atPath: pythonPath)
    }

    /// 세션 이름 중복 여부 (입력 중 실시간 체크)
    private var isNewSessionNameDuplicate: Bool {
        let name = newSessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        return sessionManager.isNameTaken(name)
    }

    // MARK: - Channel Config Detection

    /// ~/.claude.json에서 @miloveme/claude-code-api 설정을 자동 감지하여
    /// 서버 이름과 포트를 채운다.
    private func detectChannelConfig() {
        let claudeJsonPath = NSHomeDirectory() + "/.claude.json"
        guard let data = FileManager.default.contents(atPath: claudeJsonPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mcpServers = json["mcpServers"] as? [String: Any] else {
            channelConfigFound = false
            channelConfigError = "~/.claude.json 파일이 없거나 mcpServers 설정이 없습니다."
            return
        }

        // mcpServers에서 @miloveme/claude-code-api를 사용하는 항목 찾기
        for (name, value) in mcpServers {
            guard let serverConfig = value as? [String: Any],
                  let command = serverConfig["command"] as? String, command == "npx",
                  let args = serverConfig["args"] as? [String],
                  args.contains(where: { $0.hasPrefix("@miloveme/claude-code-api") }) else {
                continue
            }

            // 감지 성공 — 서버 이름 자동 설정
            newSessionChannelServerName = name

            // env에서 포트 및 API 키 가져오기
            let env = serverConfig["env"] as? [String: Any] ?? [:]
            if let portStr = env["OPENAI_COMPAT_PORT"] as? String,
               let port = Int(portStr) {
                newSessionChannelPort = port
            } else {
                newSessionChannelPort = 8787
            }

            // API 키 확인
            let hasApiKey = env["OPENAI_COMPAT_API_KEY"] as? String
            channelConfigApiKeyMissing = (hasApiKey == nil || hasApiKey!.isEmpty)

            channelConfigFound = true
            channelConfigError = ""
            return
        }

        channelConfigFound = false
        channelConfigError = "mcpServers에 @miloveme/claude-code-api 설정이 없습니다."
    }

    /// ~/.claude.json의 mcpServers에 채널 서버 설정을 추가한다.
    /// 1. 기존 파일을 .claude.json.bk로 백업
    /// 2. JSON 전체를 파싱 → mcpServers에 항목 추가 → 전체 재작성
    private func installChannelConfig() {
        let home = NSHomeDirectory()
        let claudeJsonPath = home + "/.claude.json"
        let backupPath = home + "/.claude.json.bk"
        let fileUrl = URL(fileURLWithPath: claudeJsonPath)
        let backupUrl = URL(fileURLWithPath: backupPath)
        let fm = FileManager.default
        let serverName = newSessionChannelServerName

        // 1. 기존 파일 백업
        if fm.fileExists(atPath: claudeJsonPath) {
            try? fm.removeItem(at: backupUrl)
            try? fm.copyItem(at: fileUrl, to: backupUrl)
        }

        // 2. 같은 파일에서 기존 JSON 전체 읽기
        var root: [String: Any]
        if let data = fm.contents(atPath: claudeJsonPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        } else {
            root = [:]
        }

        // 3. mcpServers에 항목 추가 (기존 항목 보존, API 키 포함)
        let apiKey = AppConfig.shared.apiKey
        var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
        mcpServers[serverName] = [
            "command": "npx",
            "args": ["-y", "@miloveme/claude-code-api@latest"],
            "env": [
                "OPENAI_COMPAT_API_KEY": apiKey
            ]
        ] as [String: Any]
        root["mcpServers"] = mcpServers

        // 4. 같은 파일에 전체 JSON 재작성
        if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? outData.write(to: fileUrl)
        }

        channelConfigInstalled = true

        // 5. 재감지
        detectChannelConfig()
    }

    /// 기존 mcpServers 설정에 API 키만 추가한다.
    private func applyChannelApiKey() {
        let home = NSHomeDirectory()
        let claudeJsonPath = home + "/.claude.json"
        let fileUrl = URL(fileURLWithPath: claudeJsonPath)
        let backupUrl = URL(fileURLWithPath: home + "/.claude.json.bk")
        let fm = FileManager.default

        guard let data = fm.contents(atPath: claudeJsonPath),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var mcpServers = root["mcpServers"] as? [String: Any],
              var serverConfig = mcpServers[newSessionChannelServerName] as? [String: Any] else {
            return
        }

        // 백업
        try? fm.removeItem(at: backupUrl)
        try? fm.copyItem(at: fileUrl, to: backupUrl)

        // env에 API 키 추가 (기존 env 보존)
        var env = serverConfig["env"] as? [String: Any] ?? [:]
        env["OPENAI_COMPAT_API_KEY"] = AppConfig.shared.apiKey
        serverConfig["env"] = env
        mcpServers[newSessionChannelServerName] = serverConfig
        root["mcpServers"] = mcpServers

        if let outData = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) {
            try? outData.write(to: fileUrl)
        }

        // 재감지
        detectChannelConfig()
    }

    /// Install 이전 상태로 복원. .claude.json.bk → .claude.json
    private func undoChannelConfig() {
        let home = NSHomeDirectory()
        let claudeJsonPath = home + "/.claude.json"
        let backupPath = home + "/.claude.json.bk"
        let fileUrl = URL(fileURLWithPath: claudeJsonPath)
        let backupUrl = URL(fileURLWithPath: backupPath)
        let fm = FileManager.default

        guard fm.fileExists(atPath: backupPath) else { return }

        try? fm.removeItem(at: fileUrl)
        try? fm.moveItem(at: backupUrl, to: fileUrl)

        channelConfigInstalled = false

        // 재감지
        detectChannelConfig()
    }
}

// MARK: - Session Detail View

struct SessionDetailView: View {
    @ObservedObject var session: Session
    @Environment(\.dismiss) private var dismiss

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f
    }()

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                Text("세션 상세 정보")
                    .font(.headline)
                Spacer()
                Button("닫기") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    detailSection("기본 정보") {
                        detailRow("이름", session.name)
                        detailRow("세션 ID", session.id)
                        detailRow("상태", session.status.rawValue)
                        detailRow("CLI 타입", session.config.cliType.displayName)
                        detailRow("생성 시각", dateFormatter.string(from: session.createdAt))
                        detailRow("메시지 수", "\(session.messageCount)")
                    }

                    detailSection("환경") {
                        detailRow("작업 디렉토리", session.config.workingDirectory)
                        detailRow("셸", session.config.shell)
                        detailRow("자동 승인", session.config.autoApprove ? "켜짐" : "꺼짐")
                        detailRow("유휴 타임아웃", "\(session.config.idleTimeout)초")
                    }

                    if session.isChannelMode {
                        detailSection("Channel Server") {
                            detailRow("포트", "\(session.config.channelPort)")
                            detailRow("서버 이름", session.config.channelServerName)
                            if let url = session.channelServerURL {
                                detailRow("URL", url)
                            }
                        }
                    }

                    if session.isSDKMode {
                        detailSection("Agent Server (SDK)") {
                            detailRow("포트", "\(session.config.sdkPort)")
                            detailRow("모델", session.config.sdkModel ?? "기본값")
                            detailRow("퍼미션 모드", session.config.sdkPermissionMode)
                            if let url = session.sdkServerURL {
                                detailRow("URL", url)
                            }
                        }
                    }

                    if session.isGeminiStreamMode {
                        detailSection("Gemini Bridge Server") {
                            detailRow("포트", "\(session.config.geminiStreamPort)")
                            if let url = session.geminiStreamServerURL {
                                detailRow("URL", url)
                            }
                        }
                    }

                    if session.isCodexAppServerMode {
                        detailSection("Codex Bridge Server") {
                            detailRow("포트", "\(session.config.codexAppServerPort)")
                            if let url = session.codexAppServerURL {
                                detailRow("URL", url)
                            }
                        }
                    }

                    if let tunnelURL = session.tunnelURL {
                        detailSection("Cloudflare Tunnel") {
                            detailRow("URL", tunnelURL)
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 520)
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .padding(.top, 16)
                .padding(.bottom, 6)
            VStack(spacing: 0) {
                content()
            }
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    @ViewBuilder
    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.callout)
                .foregroundColor(.secondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.callout)
                .foregroundColor(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        Divider().padding(.leading, 12)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    @ObservedObject var session: Session
    var onClose: () -> Void
    var onStop: (() -> Void)? = nil
    var onStart: (() -> Void)? = nil
    @State private var isHovering = false
    @State private var showCloseAlert = false
    @State private var showDetails = false

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

                // 채널 서버 URL 표시
                if session.isChannelMode, let url = session.channelServerURL {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.horizontal")
                            .font(.caption2)
                            .foregroundColor(.purple)
                        Text(url)
                            .font(.caption2)
                            .foregroundColor(.purple)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                    }
                    .help("Channel Server URL — 클릭하여 복사")
                }

                // SDK 서버 URL 표시
                if session.isSDKMode, let url = session.sdkServerURL {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .font(.caption2)
                            .foregroundColor(.cyan)
                        Text("Agent " + url)
                            .font(.caption2)
                            .foregroundColor(.cyan)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                    }
                    .help("Agent Server URL — 클릭하여 복사")
                }

                // Gemini 브릿지 서버 URL 표시
                if session.isGeminiStreamMode, let url = session.geminiStreamServerURL {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("Gemini " + url)
                            .font(.caption2)
                            .foregroundColor(.green)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                    }
                    .help("Gemini Bridge Server URL — 클릭하여 복사")
                }

                // Codex 브릿지 서버 URL 표시
                if session.isCodexAppServerMode, let url = session.codexAppServerURL {
                    HStack(spacing: 4) {
                        Image(systemName: "server.rack")
                            .font(.caption2)
                            .foregroundColor(.orange)
                        Text("Codex " + url)
                            .font(.caption2)
                            .foregroundColor(.orange)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url, forType: .string)
                            }
                    }
                    .help("Codex Bridge Server URL — 클릭하여 복사")
                }
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
        .contextMenu {
            let isRunning = [Session.Status.ready, .busy, .waitingApproval, .initializing].contains(session.status)
            // .stopped: 명시적 연결 끊기, .error: 시작 실패 — 둘 다 재연결 가능
            let canReconnect = session.status == .stopped || session.status == .error

            if isRunning, let onStop {
                Button {
                    onStop()
                } label: {
                    Label("연결 끊기", systemImage: "wifi.slash")
                }
            } else if canReconnect, let onStart {
                Button {
                    onStart()
                } label: {
                    Label("연결하기", systemImage: "wifi")
                }
            }

            Button {
                showDetails = true
            } label: {
                Label("상세 정보", systemImage: "info.circle")
            }

            Divider()

            Button(role: .destructive) {
                showCloseAlert = true
            } label: {
                Label("세션 닫기", systemImage: "xmark.circle")
            }
        }
        .sheet(isPresented: $showDetails) {
            SessionDetailView(session: session)
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
        case .stopped: return .secondary
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
