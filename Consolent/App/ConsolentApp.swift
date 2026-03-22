import SwiftUI

@main
struct ConsolentApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var sessionManager = SessionManager.shared
    @StateObject private var config = AppConfig.shared
    @StateObject private var apiServer = APIServer()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView(
                sessionManager: sessionManager,
                apiServer: apiServer,
                config: config
            )
            .onAppear {
                startAPIServer()
            }
            .onChange(of: config.apiEnabled) { oldValue, newValue in
                if newValue {
                    startAPIServer()
                } else {
                    stopAPIServer()
                }
            }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1100, height: 700)
        .commands {
            // ── File 메뉴 ──
            CommandGroup(after: .newItem) {
                Button("New Session") {
                    Task {
                        let sessionConfig = Session.Config(
                            workingDirectory: config.defaultCwd,
                            shell: config.defaultShell
                        )
                        _ = try? await sessionManager.createSession(config: sessionConfig)
                    }
                }
                .keyboardShortcut("t", modifiers: .command)

                Button("Close Session") {
                    if let id = sessionManager.selectedSessionId {
                        sessionManager.deleteSession(id: id)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
            }

            // ── View 메뉴 ──
            CommandGroup(after: .toolbar) {
                Button("Next Session") {
                    selectNextSession()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Session") {
                    selectPreviousSession()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            }

            // ── 설정 메뉴: Cmd+, 감지는 AppDelegate의 NSEvent 로컬 모니터에서 처리 ──
            // CommandGroup(replacing: .appSettings)는 키보드 단축키를 가로채지 못하므로 제거

            // ── Help 메뉴 ──
            CommandGroup(replacing: .help) {
                Button("Consolent User Guide") {
                    openWindow(id: "user-guide")
                }

                Button("API Reference") {
                    openWindow(id: "api-reference")
                }
            }
        }

        // ── 설정 윈도우 ──
        Settings {
            SettingsView(config: config, apiServer: apiServer)
        }

        // ── Help 윈도우 ──
        Window("User Guide", id: "user-guide") {
            UserGuideView()
        }
        .defaultSize(width: 700, height: 650)

        Window("API Reference", id: "api-reference") {
            APIReferenceView(config: config)
        }
        .defaultSize(width: 750, height: 700)
    }

    // MARK: - Private

    private func startAPIServer() {
        guard config.apiEnabled else {
            print("[Consolent] API server disabled in settings")
            return
        }

        Task {
            do {
                try await apiServer.start(config: config)
            } catch {
                print("[Consolent] Failed to start API server: \(error)")
                print("[Consolent] Error details: \(String(describing: error))")

                let errorDesc = String(describing: error)
                let userFriendlyError: String
                if errorDesc.contains("NIOCore.IOError") || errorDesc.contains("address already in use") {
                    userFriendlyError = "포트가 이미 사용 중입니다. 다른 포트를 지정하거나 기존 프로세스를 종료하세요."
                } else {
                    userFriendlyError = error.localizedDescription
                }

                await MainActor.run {
                    apiServer.setServerError(userFriendlyError)
                }
            }
        }

        // SessionManager 설정 동기화
        sessionManager.maxConcurrentSessions = config.maxConcurrentSessions
    }

    private func stopAPIServer() {
        print("[Consolent] Stopping API server from settings toggle")
        Task {
            await apiServer.stop()
        }
    }

    private func selectNextSession() {
        let sorted = sessionManager.sessions.values.sorted { $0.createdAt < $1.createdAt }
        guard let currentId = sessionManager.selectedSessionId,
              let currentIdx = sorted.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIdx = (currentIdx + 1) % sorted.count
        sessionManager.selectedSessionId = sorted[nextIdx].id
    }

    private func selectPreviousSession() {
        let sorted = sessionManager.sessions.values.sorted { $0.createdAt < $1.createdAt }
        guard let currentId = sessionManager.selectedSessionId,
              let currentIdx = sorted.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIdx = (currentIdx - 1 + sorted.count) % sorted.count
        sessionManager.selectedSessionId = sorted[prevIdx].id
    }
}
