import Foundation
import Vapor

/// 메신저 웹훅 수신용 독립 Vapor HTTP 서버.
/// APIServer와 완전히 분리되어 자체 포트에서 동작한다.
/// SessionManager에 직접 연결하여 HTTP 프록시 없이 세션과 통신한다.
/// 여러 봇을 동시에 등록할 수 있다 (같은 플랫폼에서도 다중 봇 가능).
final class MessengerServer: ObservableObject {

    @Published private(set) var isRunning = false
    @Published private(set) var serverError: String?
    @Published private(set) var activeBotCount = 0

    private var app: Application?
    private let dispatcher = MessageDispatcher()

    /// botId → 채널 인스턴스 매핑
    private var bots: [String: any MessengerChannel] = [:]

    /// 만료 대화 정리 타이머
    private var pruneTimer: DispatchSourceTimer?

    // MARK: - 라이프사이클

    func start(config: MessengerConfig) async throws {
        guard !isRunning else {
            throw MessengerError.serverAlreadyRunning
        }
        guard config.enabled else {
            print("[MessengerServer] 비활성 상태, 시작하지 않음")
            return
        }

        let enabledBots = config.bots.filter { $0.enabled }
        guard !enabledBots.isEmpty else {
            print("[MessengerServer] 활성 봇 없음, 시작하지 않음")
            return
        }

        print("[MessengerServer] 서버 시작 중 (\(config.bind):\(config.port))...")

        let env = Environment(name: "development", arguments: ["vapor"])
        let app = try await Application.make(env)
        app.logger.logLevel = .warning

        app.http.server.configuration.hostname = config.bind
        app.http.server.configuration.port = config.port
        app.http.server.configuration.serverName = "Consolent-Messenger"
        app.routes.defaultMaxBodySize = "10mb"

        // health 엔드포인트
        app.get("health") { _ in
            return ["status": "ok"]
        }

        // 봇별 채널 등록
        var registeredCount = 0
        for botConfig in enabledBots {
            guard let channel = createMessengerChannel(type: botConfig.channelType) else {
                print("[MessengerServer] \(botConfig.channelType.displayName) 채널 미구현, 건너뜀 (봇: \(botConfig.name))")
                continue
            }

            do {
                try channel.configure(with: botConfig)
            } catch {
                print("[MessengerServer] 봇 '\(botConfig.name)' 설정 실패: \(error.localizedDescription)")
                continue
            }

            // 메시지 콜백: 웹훅 → dispatcher → session
            let capturedBotConfig = botConfig
            let capturedDispatcher = dispatcher
            channel.onMessage = { @Sendable [weak channel] message in
                guard let channel else { return }
                await capturedDispatcher.dispatch(
                    message: message,
                    channel: channel,
                    botConfig: capturedBotConfig
                )
            }

            channel.registerRoutes(on: app)  // webhook 라우트 (터널 연결 시 사��)
            channel.startPolling()             // polling 즉시 시작 (기본 모드)
            bots[botConfig.id] = channel
            registeredCount += 1

            let sessionInfo = botConfig.targetSessionName.map { " → 세션: \($0)" } ?? " (미연결)"
            print("[MessengerServer] 봇 '\(botConfig.name)' (\(botConfig.channelType.displayName)) 등록 완료\(sessionInfo)")
        }

        guard registeredCount > 0 else {
            print("[MessengerServer] 등록된 봇 없음, 서버 시작 취소")
            try? await app.asyncShutdown()
            return
        }

        try await app.startup()
        self.app = app

        await MainActor.run {
            self.isRunning = true
            self.serverError = nil
            self.activeBotCount = registeredCount
        }

        startPruneTimer()

        print("[MessengerServer] 서버 시작 완료 — http://\(config.bind):\(config.port) (\(registeredCount)개 봇)")
    }

    func stop() async {
        pruneTimer?.cancel()
        pruneTimer = nil

        // 모든 봇의 polling 중지
        for (_, channel) in bots {
            channel.stopPolling()
        }

        if let app {
            try? await app.asyncShutdown()
            self.app = nil
        }

        bots.removeAll()

        await MainActor.run {
            self.isRunning = false
            self.serverError = nil
            self.activeBotCount = 0
        }

        print("[MessengerServer] 서버 중지")
    }

    /// 설정 변경 시 재시작.
    func restart(config: MessengerConfig) async throws {
        await stop()
        try await start(config: config)
    }

    // MARK: - 봇 조회

    /// 활성 봇 ID 목록.
    var activeBotIds: [String] {
        Array(bots.keys)
    }

    /// 특정 봇이 활성인지 확인.
    func isBotActive(id: String) -> Bool {
        bots[id]?.isActive ?? false
    }

    // MARK: - 내부

    private func startPruneTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 3600, repeating: 3600)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task {
                await self.dispatcher.pruneExpiredConversations(olderThan: 3600)
            }
        }
        timer.resume()
        pruneTimer = timer
    }
}
