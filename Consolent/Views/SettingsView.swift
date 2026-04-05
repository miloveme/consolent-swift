import SwiftUI

private extension NumberFormatter {
    /// 천 단위 구분자(콤마) 없이 정수만 표시하는 포매터
    static let plain: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.usesGroupingSeparator = false
        return f
    }()
}

/// 앱 설정 화면 (MacOS 네이티브 TabView 폼 형태)
struct SettingsView: View {

    @ObservedObject var config: AppConfig
    @ObservedObject var apiServer: APIServer
    @ObservedObject var messengerServer: MessengerServer
    @ObservedObject var messengerConfig: MessengerConfig
    @ObservedObject var sessionManager = SessionManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showKeyRegenConfirm = false
    @State private var showLogCleanupConfirm = false
    @State private var selectedTab = 0

    // 브릿지 탭 상태
    @State private var bridgeVenvReady: Bool = Session.isBridgeVenvReady
    @State private var isInstallingVenv: Bool = false
    @State private var venvInstallError: String? = nil
    @State private var venvInstallSuccess: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // 네이티브 설정 형태처럼 보이게 TabView 사용
            TabView(selection: $selectedTab) {
                generalTab
                    .tabItem {
                        Label("일반", systemImage: "gearshape")
                    }
                    .tag(0)

                apiTab
                    .tabItem {
                        Label("서버", systemImage: "network")
                    }
                    .tag(1)
                
                terminalTab
                    .tabItem {
                        Label("터미널", systemImage: "terminal")
                    }
                    .tag(2)

                bridgeTab
                    .tabItem {
                        Label("브릿지", systemImage: "cpu")
                    }
                    .tag(3)

                messengerTab
                    .tabItem {
                        Label("메신저", systemImage: "message")
                    }
                    .tag(4)
            }
            .padding()

            Divider()

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding()
            .background(VisualEffectView(material: .windowBackground, blendingMode: .withinWindow))
        }
        .frame(width: 550, height: 500)
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.openSettingsRequested)) { notification in
            if let tab = notification.object as? Int {
                selectedTab = tab
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("기본 세션 설정") {
                Picker("기본 CLI 도구", selection: $config.defaultCliType) {
                    ForEach(CLIType.allCases) { type in
                        Text(type.displayName).tag(type)
                    }
                }
                .pickerStyle(.menu)

                LabeledContent("작업 디렉토리") {
                    HStack {
                        TextField("", text: Binding(
                            get: { config.cwd(for: config.defaultCliType) },
                            set: { config.setCwd($0, for: config.defaultCliType) }
                        ))
                        .textFieldStyle(.roundedBorder)
                        Button("찾아보기…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                config.setCwd(url.path, for: config.defaultCliType)
                            }
                        }
                    }
                }

                TextField("기본 셸", text: $config.defaultShell)
                    .textFieldStyle(.roundedBorder)
            }
            
            Section("앱 동작") {
                Toggle(isOn: $config.launchToMenuBar) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("메뉴바 모드로 시작")
                        Text("앱 시작 시 윈도우를 숨기고 메뉴바 아이콘만 표시합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Section("로깅") {
                Picker("로그 레벨", selection: $config.logLevel) {
                    Text("OFF").tag("off")
                    Text("FATAL — 에러만 기록").tag("fatal")
                    Text("INFO — 파싱 결과, API 요청/응답").tag("info")
                    Text("DEBUG — INFO + PTY 원본 출력").tag("debug")
                }
                .pickerStyle(.menu)

                if config.logLevel != "off" {
                    LabeledContent("로그 보관 기간") {
                        HStack {
                            TextField("", value: $config.debugLogRetentionDays, formatter: NumberFormatter.plain)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 60)
                            Text("일")
                        }
                    }

                    LabeledContent("파일 최대 크기") {
                        HStack {
                            TextField("", value: $config.debugLogMaxFileSizeMB, formatter: NumberFormatter.plain)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 60)
                            Text("MB (초과 시 분할)")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    LabeledContent("로그 위치") {
                        Text(DebugLogger.logDirectory.path)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }

                    HStack {
                        Button("로그 폴더 열기") {
                            NSWorkspace.shared.open(DebugLogger.logDirectory)
                        }
                        Button("오래된 로그 정리") {
                            showLogCleanupConfirm = true
                        }
                        .alert("\(config.debugLogRetentionDays)일 이전 로그를 삭제하시겠습니까?",
                               isPresented: $showLogCleanupConfirm) {
                            Button("취소", role: .cancel) {}
                            Button("삭제", role: .destructive) {
                                DebugLogger.shared.cleanupOldLogs()
                            }
                        } message: {
                            Text("삭제된 로그는 복구할 수 없습니다.")
                        }
                    }
                }
            }

            Section("리소스 제한") {
                LabeledContent("최대 동시 세션") {
                    HStack {
                        TextField("", value: $config.maxConcurrentSessions, formatter: NumberFormatter.plain)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                        Spacer()
                    }
                }

                LabeledContent("유휴 시간 제한") {
                    HStack {
                        TextField("", value: $config.sessionIdleTimeout, formatter: NumberFormatter.plain)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                        Text("초 (0 = 제한 없음)")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Spacer()
                    }
                }
            }

            Section("고급") {
                TextField("프롬프트 패턴 (정규식)", text: $config.promptPattern)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .help("CLI 입력을 받을 준비가 되었는지 감지하기 위한 정규표현식 (예: > 또는 $)")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - API Server Tab

    private var apiTab: some View {
        Form {
            Section("상태") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(apiServer.serverError != nil ? Color.red : (apiServer.isRunning ? Color.green : Color.gray))
                            .frame(width: 10, height: 10)
                            .shadow(color: apiServer.serverError != nil ? .red.opacity(0.4) : (apiServer.isRunning ? .green.opacity(0.4) : .clear), radius: 2)

                        Text(apiServer.serverError != nil ? "API 서버 에러" : (apiServer.isRunning ? "API 서버 실행중" : "API 서버 중지됨"))
                            .fontWeight(.medium)

                        Spacer()
                        Toggle("", isOn: $config.apiEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    if let error = apiServer.serverError, apiServer.portConflict == nil {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 포트 충돌 UI
                    if let conflict = apiServer.portConflict {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundColor(.orange)
                                Text("포트 \(conflict.port) 충돌")
                                    .fontWeight(.semibold)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text("\"\(conflict.displayName)\" 이(가) 포트 \(conflict.port)를 사용 중입니다.")
                                    .font(.callout)
                                if !conflict.displayCommand.isEmpty {
                                    Text(conflict.displayCommand)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Text("PID: \(conflict.pids.map { String($0) }.joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }

                            HStack(spacing: 10) {
                                Button("강제 종료") {
                                    apiServer.killConflictingProcesses()
                                    apiServer.retryStart(config: config)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(.red)

                                Button("포트 \(conflict.suggestedPort) 사용") {
                                    config.apiPort = conflict.suggestedPort
                                    apiServer.portConflict = nil
                                    apiServer.retryStart(config: config)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                        .padding()
                        .background(Color.orange.opacity(0.1))
                        .cornerRadius(8)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("네트워크 설정") {
                HStack {
                    TextField("포트", value: $config.apiPort, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                    Spacer()
                }

                Picker("바인딩 주소", selection: $config.apiBind) {
                    Text("로컬호스트 (127.0.0.1)").tag("127.0.0.1")
                    Text("모든 인터페이스 (0.0.0.0)").tag("0.0.0.0")
                }
                .pickerStyle(.menu)

                if config.apiBind == "0.0.0.0" {
                    Text("⚠️ 모든 인터페이스에 노출하는 것은 보안 위험이 될 수 있습니다. 신뢰할 수 있는 네트워크에서만 사용하세요.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top, 2)
                }
            }

            Section("인증 및 출력") {
                LabeledContent("API 키") {
                    HStack {
                        Text(config.apiKey)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .textBackgroundColor))
                            .cornerRadius(4)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.2)))

                        Button(action: {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(config.apiKey, forType: .string)
                        }) {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.accentColor)
                        .help("API 키 복사")

                        Button(action: {
                            showKeyRegenConfirm = true
                        }) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                        .buttonStyle(.plain)
                        .foregroundColor(.orange)
                        .help("키 재발급")
                    }
                }

                Toggle(isOn: $config.includeRawOutput) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("원시 출력 포함")
                        Text("API 응답에 일반 텍스트 이외에 ANSI 색상이 포함된 출력을 반환합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 4)
            }

            Section("자동 강제 복구") {
                Toggle(isOn: $config.autoForceRecovery) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("자동 강제 복구 모드")
                        Text("포트 충돌 등 시작 오류 발생 시 사용자 확인 없이 기존 프로세스를 강제 종료하고 자동으로 재시작합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        if config.autoForceRecovery {
                            Text("⚡ 활성화됨 — 맥 재부팅 후에도 세션이 자동으로 복구됩니다.")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
            }

            cloudflareSection
        }
        .formStyle(.grouped)
        .alert("API 키를 재발급하시겠습니까?", isPresented: $showKeyRegenConfirm) {
            Button("취소", role: .cancel) {}
            Button("재발급", role: .destructive) {
                config.regenerateKey()
            }
        } message: {
            Text("기존 클라이언트 스크립트는 새로운 키로 업데이트해야 합니다.")
        }
    }

    // MARK: - Terminal Tab

    private var terminalTab: some View {
        Form {
            Section("모양") {
                LabeledContent("글꼴 패밀리") {
                    TextField("", text: $config.fontFamily)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 180)
                }

                LabeledContent("글꼴 크기") {
                    HStack {
                        TextField("", value: $config.fontSize, formatter: NumberFormatter.plain)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 60)
                        Text("pt")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Spacer()
                    }
                }

                Picker("테마", selection: $config.theme) {
                    Text("다크").tag("dark")
                    Text("라이트").tag("light")
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }

            Section("버퍼 제한") {
                LabeledContent("UI 스크롤백") {
                    HStack {
                        TextField("", value: $config.scrollbackLines, formatter: NumberFormatter.plain)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                        Text("줄")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Spacer()
                    }
                }

                LabeledContent("API 응답 버퍼") {
                    HStack {
                        TextField("", value: $config.headlessTerminalRows, formatter: NumberFormatter.plain)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                        Text("줄")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Spacer()
                    }
                }
                Text("API 출력 파싱을 위해 보존되는 원시 기록의 양입니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if config.headlessTerminalRows > config.scrollbackLines {
                    Text("⚠️ 주의: 스크롤백이 API 버퍼보다 작습니다. UI에서 일부 응답이 잘릴 수 있습니다.")
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.top, 4)
                    }
                
                LabeledContent("메모리 제한") {
                    HStack {
                        TextField("", value: $config.outputBufferMB, formatter: NumberFormatter.plain)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 100)
                        Text("MB (세션당)")
                            .foregroundColor(.secondary)
                            .font(.caption)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Bridge Tab

    private var bridgeTab: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SDK / Gemini / Codex 브릿지 서버는 Python 가상환경을 공유합니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("세션을 만들기 전에 미리 설치해두면 첫 세션 시작이 빨라집니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 2)
            } header: {
                Text("Python 가상환경 (공용)")
            }

            Section("설치 경로") {
                LabeledContent("가상환경 위치") {
                    HStack {
                        TextField("", text: $config.sdkVenvPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.caption, design: .monospaced))
                        Button("찾아보기…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            if panel.runModal() == .OK, let url = panel.url {
                                config.sdkVenvPath = url.path
                                bridgeVenvReady = Session.isBridgeVenvReady
                            }
                        }
                        .controlSize(.small)
                    }
                }

                LabeledContent("상태") {
                    HStack(spacing: 6) {
                        if bridgeVenvReady {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.green)
                            Text("설치됨")
                                .foregroundColor(.green)
                        } else {
                            Image(systemName: "circle")
                                .foregroundColor(.secondary)
                            Text("설치 필요")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if let error = venvInstallError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if venvInstallSuccess && bridgeVenvReady {
                    Label("설치 완료!", systemImage: "checkmark.seal.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                }

                HStack {
                    Button {
                        isInstallingVenv = true
                        venvInstallError = nil
                        venvInstallSuccess = false
                        Task {
                            do {
                                try await Session.installBridgeVenv()
                                await MainActor.run {
                                    bridgeVenvReady = Session.isBridgeVenvReady
                                    isInstallingVenv = false
                                    venvInstallSuccess = true
                                }
                            } catch {
                                await MainActor.run {
                                    venvInstallError = error.localizedDescription
                                    isInstallingVenv = false
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if isInstallingVenv {
                                ProgressView().controlSize(.mini)
                            }
                            Text(isInstallingVenv ? "설치 중..." : (bridgeVenvReady ? "재설치" : "지금 설치"))
                        }
                    }
                    .disabled(isInstallingVenv)

                    Button("상태 새로고침") {
                        bridgeVenvReady = Session.isBridgeVenvReady
                        venvInstallSuccess = false
                    }
                    .disabled(isInstallingVenv)
                }
            }

            Section("브릿지 출력 레벨") {
                Picker("출력 레벨", selection: $config.bridgeLogLevel) {
                    Text("오류만").tag("error")
                    Text("정보 (기본)").tag("info")
                    Text("디버그 (원시 출력 포함)").tag("debug")
                }
                .pickerStyle(.menu)

                Group {
                    switch config.bridgeLogLevel {
                    case "error":
                        Label("❌ 오류 메시지만 표시합니다.", systemImage: "info.circle")
                    case "debug":
                        Label("[Gemini 원시 출력] 등 진단 메시지를 모두 표시합니다.", systemImage: "info.circle")
                    default:
                        Label("서버 시작·종료 등 상태 메시지를 표시합니다.", systemImage: "info.circle")
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)

                Text("변경은 새 세션을 시작할 때부터 적용됩니다.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Section("API 라우팅") {
                Toggle(isOn: $config.proxyBridgeRequests) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("브릿지 요청 프록시")
                        Text("켜면 localhost:9999로 보낸 요청을 Consolent이 자동으로 Agent/브릿지 서버로 포워딩합니다. 꺼져 있으면 410 Gone + 브릿지 URL을 반환합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if config.proxyBridgeRequests {
                    Label("단일 엔드포인트 모드: localhost:\(config.apiPort)으로 모든 세션 접근 가능", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption)
                        .foregroundColor(.blue)
                } else {
                    Label("직접 연결 모드: Agent/브릿지 세션은 각 브릿지 서버 URL로 직접 요청", systemImage: "arrow.right")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("포함 패키지") {
                VStack(alignment: .leading, spacing: 4) {
                    Label("claude-agent-sdk", systemImage: "shippingbox")
                        .font(.caption)
                    Label("aiohttp", systemImage: "shippingbox")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                Text("설치 시 uv 또는 pip을 자동으로 사용합니다. uv가 있으면 Python 3.12를 자동 설치합니다.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            bridgeVenvReady = Session.isBridgeVenvReady
        }
    }

    // MARK: - Messenger Tab

    @State private var showAddBotSheet = false
    @State private var editingBotId: String? = nil

    private var messengerTab: some View {
        Form {
            Section("상태") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(messengerServer.isRunning ? Color.green : Color.gray)
                            .frame(width: 10, height: 10)
                            .shadow(color: messengerServer.isRunning ? .green.opacity(0.4) : .clear, radius: 2)

                        Text(messengerServer.isRunning
                             ? "메신저 서버 실행중 (\(messengerServer.activeBotCount)개 봇)"
                             : "메신저 서버 중지됨")
                            .fontWeight(.medium)

                        Spacer()
                        Toggle("", isOn: $messengerConfig.enabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    if let error = messengerServer.serverError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
                .padding(.vertical, 4)
            }

            Section("네트워크 설정") {
                HStack {
                    TextField("포트", value: $messengerConfig.port, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 100)
                    Spacer()
                }

                Picker("바인딩 주소", selection: $messengerConfig.bind) {
                    Text("로컬호스트 (127.0.0.1)").tag("127.0.0.1")
                    Text("모든 인터페이스 (0.0.0.0)").tag("0.0.0.0")
                }
                .pickerStyle(.menu)
            }

            Section {
                if messengerConfig.bots.isEmpty {
                    Text("등록된 봇이 없습니다. 봇을 추가하세요.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    ForEach(messengerConfig.bots) { bot in
                        messengerBotRow(bot: bot)
                    }
                }

                Button {
                    showAddBotSheet = true
                } label: {
                    Label("봇 추가", systemImage: "plus.circle")
                }
            } header: {
                Text("등록된 봇")
            }

            Section {
                HStack {
                    Button("설정 저장") {
                        messengerConfig.save()
                    }
                    .buttonStyle(.borderedProminent)

                    Button("서버 재시작") {
                        messengerConfig.save()
                        Task {
                            try? await messengerServer.restart(config: messengerConfig)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!messengerConfig.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddBotSheet) {
            MessengerBotEditSheet(
                messengerConfig: messengerConfig,
                sessionManager: sessionManager,
                botConfig: nil
            )
        }
        .sheet(item: Binding(
            get: { editingBotId.flatMap { id in messengerConfig.bots.first { $0.id == id } } },
            set: { editingBotId = $0?.id }
        )) { bot in
            MessengerBotEditSheet(
                messengerConfig: messengerConfig,
                sessionManager: sessionManager,
                botConfig: bot
            )
        }
    }

    @ViewBuilder
    private func messengerBotRow(bot: MessengerBotConfig) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(bot.enabled ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(bot.name.isEmpty ? bot.channelType.displayName : bot.name)
                        .fontWeight(.medium)
                    Text("(\(bot.channelType.displayName))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack(spacing: 8) {
                    if let session = bot.targetSessionName {
                        Label(session, systemImage: "link")
                            .font(.caption)
                            .foregroundColor(.blue)
                    } else {
                        Label("미연결", systemImage: "link.badge.plus")
                            .font(.caption)
                            .foregroundColor(.orange)
                    }

                    if !bot.allowedUserIds.isEmpty {
                        Label("\(bot.allowedUserIds.count)명", systemImage: "person.badge.shield.checkmark")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                editingBotId = bot.id
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Button {
                messengerConfig.removeBot(id: bot.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Cloudflare Tunnel (세션별)

    @ViewBuilder
    private var cloudflareSection: some View {
        let activeSessions = Array(sessionManager.sessions.values)
            .filter { $0.status != .terminated }
            .sorted { $0.createdAt < $1.createdAt }

        Section("Cloudflare Quick Tunnel") {
            if activeSessions.isEmpty {
                Label("활성 세션이 없습니다. 세션을 먼저 생성하세요.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                Label("세션별로 터널을 켜고 끌 수 있습니다. cloudflared 미설치 시 자동 설치됩니다.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundColor(.secondary)

                ForEach(activeSessions) { session in
                    tunnelRow(session: session)
                }
            }
        }
    }

    @ViewBuilder
    private func tunnelRow(session: Session) -> some View {
        let isBusy: Bool = {
            switch session.cloudflare.tunnelState {
            case .installing, .starting: return true
            default: return false
            }
        }()

        let isOn = Binding<Bool>(
            get: { session.cloudflare.tunnelState != .idle },
            set: { enabled in
                if enabled {
                    sessionManager.startTunnel(sessionId: session.id)
                } else {
                    sessionManager.stopTunnel(sessionId: session.id)
                }
            }
        )

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: isOn) {
                    HStack(spacing: 4) {
                        Text(session.id)
                            .font(.system(.caption, design: .monospaced))
                        Text("(\(session.config.cliType.displayName))")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isBusy)

                Spacer()

                if isBusy {
                    ProgressView().controlSize(.mini)
                }
            }

            switch session.cloudflare.tunnelState {
            case .running(let url):
                HStack(spacing: 4) {
                    Image(systemName: "globe")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text(url)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundColor(.blue)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.caption2)
                    }
                    .buttonStyle(.plain)
                    .help("URL 복사")
                }
                .padding(.leading, 20)
            case .error(let msg):
                Label(msg, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .lineLimit(1)
                    .padding(.leading, 20)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - 봇 편집 시트

/// 메신저 봇 추가/편집 시트.
struct MessengerBotEditSheet: View {

    @ObservedObject var messengerConfig: MessengerConfig
    @ObservedObject var sessionManager: SessionManager

    /// nil이면 새 봇 추가, 값이 있으면 편집.
    let botConfig: MessengerBotConfig?

    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var channelType: MessengerChannelType = .telegram
    @State private var enabled: Bool = true
    @State private var targetSessionName: String = ""
    @State private var botToken: String = ""
    @State private var webhookSecret: String = ""
    @State private var allowedUserIdsText: String = ""
    @State private var systemPrompt: String = ""
    @State private var maxHistoryTurns: Int = 10
    @State private var responseTimeout: Int = 300

    // 연결 테스트 상태
    @State private var isTesting = false
    @State private var testResult: (success: Bool, message: String)? = nil

    private var isEditing: Bool { botConfig != nil }

    var body: some View {
        VStack(spacing: 0) {
            Text(isEditing ? "봇 편집" : "봇 추가")
                .font(.headline)
                .padding()

            Form {
                Section("기본 정보") {
                    TextField("봇 이름", text: $name)
                        .textFieldStyle(.roundedBorder)

                    Picker("플랫폼", selection: $channelType) {
                        ForEach(MessengerChannelType.allCases.filter { $0.isSupported }, id: \.self) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(isEditing)

                    Toggle("활성화", isOn: $enabled)
                }

                Section("세션 연결") {
                    let sessionNames = Array(sessionManager.sessions.values)
                        .filter { $0.status != .terminated }
                        .map { $0.name }
                        .sorted()

                    Picker("대상 세션", selection: $targetSessionName) {
                        Text("(미연결)").tag("")
                        ForEach(sessionNames, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.menu)

                    Text("이 봇으로 수신된 메시지가 선택한 세션으로 전달됩니다.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("자격증명") {
                    if channelType == .telegram {
                        SecureField("Bot Token", text: $botToken)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))

                        TextField("Webhook Secret (선택사항)", text: $webhookSecret)
                            .textFieldStyle(.roundedBorder)

                        Text("@BotFather에서 봇을 생성하고 토큰을 입력하세요.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("보안") {
                    TextField("허용 사용자 ID (콤마 구분)", text: $allowedUserIdsText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))

                    Text("빈칸이면 모든 사용자 허용. Telegram: @userinfobot으로 ID 확인 가능.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("고급") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("시스템 프롬프트 (선택사항)")
                            .font(.callout)
                            .foregroundColor(.secondary)
                        TextEditor(text: $systemPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 60, maxHeight: 120)
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(6)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.2)))
                    }

                    LabeledContent("대화 히스토리") {
                        HStack {
                            TextField("", value: $maxHistoryTurns, formatter: NumberFormatter.plain)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 60)
                            Text("턴")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }

                    LabeledContent("응답 타임아웃") {
                        HStack {
                            TextField("", value: $responseTimeout, formatter: NumberFormatter.plain)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 80)
                            Text("초")
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                }

                if channelType == .telegram && !botToken.isEmpty {
                    Section("연결 테스트") {
                        HStack {
                            Button {
                                runConnectionTest()
                            } label: {
                                HStack(spacing: 4) {
                                    if isTesting {
                                        ProgressView().controlSize(.mini)
                                    }
                                    Text(isTesting ? "테스트 중..." : "연결 테스트")
                                }
                            }
                            .disabled(isTesting)

                            Spacer()
                        }

                        if let result = testResult {
                            Label {
                                Text(result.message)
                                    .font(.caption)
                                    .fixedSize(horizontal: false, vertical: true)
                            } icon: {
                                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .foregroundColor(result.success ? .green : .red)
                            }
                        }

                        Text("토큰을 검증하고, 허용 사용자가 설정되어 있으면 인사 메시지를 보냅니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(isEditing ? "저장" : "추가") {
                    saveBot()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(botToken.isEmpty && channelType == .telegram)
            }
            .padding()
        }
        .frame(width: 480, height: 660)
        .onAppear {
            if let bot = botConfig {
                name = bot.name
                channelType = bot.channelType
                enabled = bot.enabled
                targetSessionName = bot.targetSessionName ?? ""
                botToken = bot.credentials["botToken"] ?? ""
                webhookSecret = bot.credentials["webhookSecret"] ?? ""
                allowedUserIdsText = bot.allowedUserIds.joined(separator: ", ")
                systemPrompt = bot.systemPrompt ?? ""
                maxHistoryTurns = bot.maxHistoryTurns
                responseTimeout = bot.responseTimeout
            }
        }
    }

    private func saveBot() {
        var bot = botConfig ?? MessengerBotConfig(channelType: channelType)
        bot.name = name
        bot.enabled = enabled
        bot.targetSessionName = targetSessionName.isEmpty ? nil : targetSessionName
        bot.systemPrompt = systemPrompt.isEmpty ? nil : systemPrompt
        bot.maxHistoryTurns = maxHistoryTurns
        bot.responseTimeout = responseTimeout

        // 자격증명
        if channelType == .telegram {
            bot.credentials["botToken"] = botToken
            bot.credentials["webhookSecret"] = webhookSecret
        }

        // 허용 사용자 파싱
        bot.allowedUserIds = allowedUserIdsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        messengerConfig.setBotConfig(bot)
    }

    private func runConnectionTest() {
        isTesting = true
        testResult = nil

        // 현재 입력값으로 임시 봇 설정 구성
        var tempBot = botConfig ?? MessengerBotConfig(channelType: channelType)
        tempBot.name = name
        tempBot.credentials["botToken"] = botToken
        tempBot.targetSessionName = targetSessionName.isEmpty ? nil : targetSessionName
        tempBot.allowedUserIds = allowedUserIdsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        Task {
            let (success, message) = await TelegramChannel.testConnection(botConfig: tempBot)
            await MainActor.run {
                testResult = (success, message)
                isTesting = false
            }
        }
    }
}
