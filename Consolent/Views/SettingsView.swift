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
    @ObservedObject var sessionManager = SessionManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showKeyRegenConfirm = false
    @State private var showLogCleanupConfirm = false
    @State private var selectedTab = 0

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
        .frame(width: 550, height: 450)
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
                .pickerStyle(.radioGroup)

                if config.logLevel != "off" {
                    LabeledContent("로그 보관 기간") {
                        HStack {
                            TextField("", value: $config.debugLogRetentionDays, formatter: NumberFormatter.plain)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 60)
                            Text("일")
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
                    
                    if let error = apiServer.serverError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
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
