import SwiftUI

@main
struct ConsolentApp: App {

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @StateObject private var sessionManager = SessionManager.shared
    @StateObject private var config = AppConfig.shared
    @StateObject private var apiServer = APIServer()
    @StateObject private var messengerServer = MessengerServer()
    @StateObject private var messengerConfig = MessengerConfig.load()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            ContentView(
                sessionManager: sessionManager,
                apiServer: apiServer,
                config: config,
                messengerConfig: messengerConfig
            )
            .onAppear {
                startAPIServer()
                startMessengerServer()
            }
            .onChange(of: config.apiEnabled) { oldValue, newValue in
                if newValue {
                    startAPIServer()
                } else {
                    stopAPIServer()
                }
            }
            .onChange(of: messengerConfig.enabled) { oldValue, newValue in
                if newValue {
                    startMessengerServer()
                } else {
                    stopMessengerServer()
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

            // ── View 메뉴 추가 항목 ──
            CommandGroup(after: .sidebar) {
                Divider()
                Button("대화 히스토리") {
                    openWindow(id: "conversation-history")
                }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            }

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
            SettingsView(config: config, apiServer: apiServer,
                         messengerServer: messengerServer, messengerConfig: messengerConfig)
        }

        // ── 대화 히스토리 윈도우 ──
        Window("대화 히스토리", id: "conversation-history") {
            ConversationHistoryView()
        }
        .defaultSize(width: 800, height: 600)

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

                // String(describing:)와 localizedDescription 모두 체크 (NIO 에러 표현 방식이 다양함)
                let allErrorText = String(describing: error) + " " + error.localizedDescription
                let isPortConflict = allErrorText.contains("NIOCore.IOError") ||
                                     allErrorText.contains("address already in use") ||
                                     allErrorText.contains("EADDRINUSE")
                let userFriendlyError: String
                if isPortConflict {
                    userFriendlyError = "포트가 이미 사용 중입니다."
                } else {
                    userFriendlyError = error.localizedDescription
                }

                await MainActor.run {
                    apiServer.setServerError(userFriendlyError)
                }

                // 포트 충돌이면 충돌 정보 수집
                if isPortConflict {
                    await apiServer.detectAndSetPortConflict(port: config.apiPort)
                    // 자동 강제 복구 모드: 충돌 프로세스 즉시 종료 후 재시작
                    if config.autoForceRecovery {
                        print("[Consolent] 자동 강제 복구: 포트 \(config.apiPort) 충돌 프로세스 종료 후 재시작")
                        apiServer.killConflictingProcesses()
                        apiServer.retryStart(config: config)
                    }
                }
            }

            // API 서버 성공/실패 여부와 무관하게 이전 세션 항상 복원
            await sessionManager.restoreFromStorage()
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

    private func startMessengerServer() {
        guard messengerConfig.enabled else { return }
        Task {
            do {
                try await messengerServer.start(config: messengerConfig)
            } catch {
                print("[Consolent] Failed to start messenger server: \(error)")
            }
        }
    }

    private func stopMessengerServer() {
        Task {
            await messengerServer.stop()
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
