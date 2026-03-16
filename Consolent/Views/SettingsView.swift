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

/// 앱 설정 화면
struct SettingsView: View {

    @ObservedObject var config: AppConfig
    @ObservedObject var apiServer: APIServer
    @ObservedObject var sessionManager = SessionManager.shared

    @Environment(\.dismiss) private var dismiss

    @State private var showKeyRegenConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            HStack {
                Text("Settings")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    apiSection
                    sessionSection
                    claudeSection
                    terminalSection
                }
                .padding(20)
            }
        }
        .frame(width: 550, height: 600)
    }

    // MARK: - API Server

    private var apiSection: some View {
        GroupBox("API Server") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Enable API Server", isOn: $config.apiEnabled)

                HStack {
                    Text("Port:")
                        .frame(width: 100, alignment: .trailing)
                    TextField("", value: $config.apiPort, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                }

                HStack {
                    Text("Bind Address:")
                        .frame(width: 100, alignment: .trailing)
                    Picker("", selection: $config.apiBind) {
                        Text("Localhost (127.0.0.1)").tag("127.0.0.1")
                        Text("All Interfaces (0.0.0.0)").tag("0.0.0.0")
                    }
                    .labelsHidden()
                }

                if config.apiBind == "0.0.0.0" {
                    Label("Exposing to network. Only do this on trusted networks.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }

                HStack {
                    Text("API Key:")
                        .frame(width: 100, alignment: .trailing)
                    Text(config.apiKey)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(4)
                        .background(Color(nsColor: .textBackgroundColor))
                        .cornerRadius(4)

                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(config.apiKey, forType: .string)
                    }
                    .controlSize(.small)

                    Button("Regenerate") {
                        showKeyRegenConfirm = true
                    }
                    .controlSize(.small)
                    .alert("Regenerate API Key?", isPresented: $showKeyRegenConfirm) {
                        Button("Cancel", role: .cancel) {}
                        Button("Regenerate", role: .destructive) {
                            config.regenerateKey()
                        }
                    } message: {
                        Text("Existing clients will need the new key.")
                    }
                }

                Toggle("Include raw output in responses", isOn: $config.includeRawOutput)

                Divider()

                cloudflareSection

                HStack {
                    Text("Status:")
                        .frame(width: 100, alignment: .trailing)
                    Circle()
                        .fill(apiServer.isRunning ? Color.green : Color.red)
                        .frame(width: 8, height: 8)
                    Text(verbatim: apiServer.isRunning ? "Running on :\(config.apiPort)" : "Stopped")
                        .font(.caption)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Sessions

    private var sessionSection: some View {
        GroupBox("Sessions") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Max Concurrent:")
                        .frame(width: 130, alignment: .trailing)
                    TextField("", value: $config.maxConcurrentSessions, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                }

                HStack {
                    Text("Idle Timeout (sec):")
                        .frame(width: 130, alignment: .trailing)
                    TextField("", value: $config.sessionIdleTimeout, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("0 = no timeout")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Buffer per Session:")
                        .frame(width: 130, alignment: .trailing)
                    TextField("", value: $config.outputBufferMB, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("MB")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: - CLI Tool

    private var claudeSection: some View {
        GroupBox("CLI Tool") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Default CLI:")
                        .frame(width: 110, alignment: .trailing)
                    Picker("", selection: $config.defaultCliType) {
                        ForEach(CLIType.allCases) { type in
                            Text(type.displayName).tag(type)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 200)
                }

                HStack {
                    Text("Default Shell:")
                        .frame(width: 110, alignment: .trailing)
                    TextField("", text: $config.defaultShell)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                HStack {
                    Text("Default CWD:")
                        .frame(width: 110, alignment: .trailing)
                    TextField("", text: $config.defaultCwd)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url {
                            config.defaultCwd = url.path
                        }
                    }
                    .controlSize(.small)
                }

                HStack {
                    Text("Prompt Pattern:")
                        .frame(width: 110, alignment: .trailing)
                    TextField("Regex", text: $config.promptPattern)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 200)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Terminal

    private var terminalSection: some View {
        GroupBox("Terminal") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("글꼴:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", text: $config.fontFamily)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 150)
                    TextField("", value: $config.fontSize, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                    Text("pt")
                        .font(.caption)
                }

                HStack {
                    Text("테마:")
                        .frame(width: 120, alignment: .trailing)
                    Picker("", selection: $config.theme) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }

                HStack {
                    Text("화면 스크롤 기록:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", value: $config.scrollbackLines, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("줄")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("API 응답 버퍼:")
                        .frame(width: 120, alignment: .trailing)
                    TextField("", value: $config.headlessTerminalRows, formatter: NumberFormatter.plain)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text("줄")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if config.headlessTerminalRows > config.scrollbackLines {
                    Label("스크롤 기록이 API 응답 버퍼보다 작으면 화면에서 전체 응답을 볼 수 없습니다",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }
            .padding(8)
        }
    }

    // MARK: - Cloudflare Tunnel (세션별)

    @ViewBuilder
    private var cloudflareSection: some View {
        let activeSessions = Array(sessionManager.sessions.values)
            .filter { $0.status != .terminated }
            .sorted { $0.createdAt < $1.createdAt }

        if activeSessions.isEmpty {
            Text("Cloudflare Quick Tunnel")
                .font(.caption)
                .fontWeight(.medium)
            Label("활성 세션이 없습니다. 세션을 먼저 생성하세요.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Text("Cloudflare Quick Tunnel")
                .font(.caption)
                .fontWeight(.medium)
            Label("세션별로 터널을 켜고 끌 수 있습니다. cloudflared 미설치 시 자동 설치됩니다.",
                  systemImage: "info.circle")
                .font(.caption)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(activeSessions) { session in
                    tunnelRow(session: session)
                }
            }
            .padding(.top, 4)
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
