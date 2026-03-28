import Foundation
import Combine

/// 모든 세션의 생명주기를 관리한다.
/// SwiftUI 뷰와 API 서버 양쪽에서 접근한다.
final class SessionManager: ObservableObject {

    static let shared = SessionManager()

    @Published private(set) var sessions: [String: Session] = [:]
    @Published var selectedSessionId: String? = nil

    /// 사이드바 표시 순서. 세션 ID 배열. 드래그로 변경 가능하며 sessions.json에 영속화.
    @Published var sessionOrder: [String] = []

    /// 전체 복원 진행 중 여부. true일 때 복원 프로그레스 오버레이 표시.
    @Published var isRestoring: Bool = false
    /// 채널 세션 순차 복원 중 여부. true일 때 UI 세션 전환 클릭 차단.
    @Published var isRestoringChannelSessions: Bool = false
    /// 현재까지 시작된 세션 수
    @Published var restoringCurrent: Int = 0
    /// 복원할 전체 세션 수
    @Published var restoringTotal: Int = 0

    var maxConcurrentSessions: Int = 10

    private var cancellables = Set<AnyCancellable>()

    private init() {}

    // MARK: - Session Persistence

    /// 세션 상태를 저장하는 별도 파일 (config.json과 분리).
    /// 경로: ~/Library/Application Support/Consolent/sessions.json
    private static var sessionsStoreURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Consolent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("sessions.json")
    }

    /// 현재 활성 세션의 Config를 sessions.json에 저장한다.
    /// 종료된 세션은 저장하지 않는다.
    func saveToStorage() {
        // sessionOrder 순서대로 config를 저장하여 복원 시 순서 유지
        let entries = sessionOrder
            .compactMap { sessions[$0] }
            .filter { $0.status != .terminated }
            .map { session in
                PersistedSessionEntry(
                    config: session.config,
                    wasConnected: session.status != .stopped
                )
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: Self.sessionsStoreURL, options: .atomic)
    }

    /// 세션 프로세스를 중지하되 세션 객체는 유지한다 (메뉴 "세션 중지").
    func stopSession(id: String) {
        sessions[id]?.stopProcess()
    }

    /// 중지 또는 에러 상태의 세션을 재시작한다.
    func startSession(id: String) async throws {
        guard let session = sessions[id],
              session.status == .stopped || session.status == .error else { return }
        try await session.start()
    }

    /// 복원용: 세션 객체를 .stopped 상태로 등록만 한다 (start 호출 안 함).
    @discardableResult
    private func registerRestoredSession(config: Session.Config) -> Session? {
        guard sessions.count < maxConcurrentSessions else { return nil }

        var finalConfig = config
        // 포트 충돌 방지
        if finalConfig.channelEnabled {
            var port = finalConfig.channelPort
            while isChannelPortInUse(port) { port += 1 }
            finalConfig.channelPort = port
        }
        if finalConfig.sdkEnabled {
            var port = finalConfig.sdkPort
            while isBridgePortInUse(port) { port += 1 }
            finalConfig.sdkPort = port
        }
        if finalConfig.geminiStreamEnabled {
            var port = finalConfig.geminiStreamPort
            while isBridgePortInUse(port) { port += 1 }
            finalConfig.geminiStreamPort = port
        }
        if finalConfig.codexAppServerEnabled {
            var port = finalConfig.codexAppServerPort
            while isBridgePortInUse(port) { port += 1 }
            finalConfig.codexAppServerPort = port
        }

        let session = Session(config: finalConfig, initialStatus: .stopped)

        nonisolated(unsafe) let weakSelf = self
        session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { _ in
                DispatchQueue.main.async {
                    weakSelf.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        sessions[session.id] = session
        sessionOrder.append(session.id)
        if selectedSessionId == nil {
            selectedSessionId = session.id
        }
        return session
    }

    /// sessions.json에서 세션을 복원하여 재시작한다.
    /// 앱 시작 시 1회 호출.
    /// - PTY/브릿지 세션: 동시에 시작
    /// - Channel 세션: 순차 시작 (UI 잠금 + 진행 표시)
    func restoreFromStorage() async {
        guard let data = try? Data(contentsOf: Self.sessionsStoreURL) else { return }

        // 신규 포맷(PersistedSessionEntry) 우선 시도, 실패 시 구 포맷(Session.Config) 폴백
        let entries: [PersistedSessionEntry]
        if let newFormat = try? JSONDecoder().decode([PersistedSessionEntry].self, from: data) {
            entries = newFormat
        } else if let oldFormat = try? JSONDecoder().decode([Session.Config].self, from: data) {
            // 구 포맷 마이그레이션: 모두 wasConnected = true로 처리
            entries = oldFormat.map { PersistedSessionEntry(config: $0, wasConnected: true) }
        } else {
            return
        }
        guard !entries.isEmpty else { return }

        // 0단계: 작업 디렉토리 접근 권한 사전 확보 (TCC 프리플라이트)
        // 복원 오버레이가 표시되기 전에 macOS 파일 접근 권한 다이얼로그를 먼저 처리한다.
        // 다이얼로그는 커널 레벨에서 파일 접근을 블록하므로, 사용자 응답 후 자동으로 진행된다.
        await preflightDirectoryAccess(entries: entries)

        // 1단계: 모든 세션 객체를 .stopped 상태로 등록 → UI에 즉시 전부 표시
        var channelSessionsToStart: [Session] = []
        var otherSessionsToStart: [Session] = []

        await MainActor.run {
            for entry in entries {
                guard let session = registerRestoredSession(config: entry.config) else {
                    print("[SessionManager] 세션 복원 등록 실패 (\(entry.config.name ?? entry.config.cliType.rawValue)): 최대 세션 수 초과")
                    continue
                }
                // wasConnected인 세션만 자동 시작 목록에 추가
                if entry.wasConnected {
                    if session.isChannelMode {
                        channelSessionsToStart.append(session)
                    } else {
                        otherSessionsToStart.append(session)
                    }
                }
            }
            // 전체 복원 프로그레스 시작 (자동 연결 세션이 있는 경우에만)
            restoringTotal = otherSessionsToStart.count + channelSessionsToStart.count
            restoringCurrent = 0
            isRestoring = restoringTotal > 0
        }

        defer {
            Task { @MainActor in
                isRestoring = false
                isRestoringChannelSessions = false
                restoringCurrent = 0
                restoringTotal = 0
            }
        }

        // 2단계: PTY/브릿지 세션 동시 시작 (전체 진행 카운트 포함)
        await withTaskGroup(of: Void.self) { group in
            for session in otherSessionsToStart {
                group.addTask {
                    do {
                        try await session.start()
                    } catch {
                        print("[SessionManager] 세션 복원 실패 (\(session.name)): \(error)")
                    }
                    await MainActor.run { self.restoringCurrent += 1 }
                }
            }
        }

        // 3단계: Channel 세션 순차 시작 (UI 잠금)
        guard !channelSessionsToStart.isEmpty else { return }

        await MainActor.run {
            isRestoringChannelSessions = true
        }

        for session in channelSessionsToStart {
            await MainActor.run {
                restoringCurrent += 1
                selectedSessionId = session.id  // 해당 세션으로 포커스 고정
            }
            // SwiftUI가 TerminalView를 해당 세션에 attach할 시간 확보
            // Channel auto-enter는 headless terminal 출력을 읽으므로 attach 완료 후 시작해야 함
            try? await Task.sleep(nanoseconds: 300_000_000) // 0.3초
            do {
                try await session.start()
                // ready 상태가 될 때까지 대기 (최대 60초)
                let deadline = Date().addingTimeInterval(60)
                while session.status == .initializing || session.status == .busy {
                    if Date() > deadline { break }
                    try await Task.sleep(nanoseconds: 300_000_000)
                }
            } catch {
                print("[SessionManager] 채널 세션 복원 실패 (\(session.name)): \(error)")
            }
        }
    }

    // MARK: - Session CRUD

    /// 새 세션을 생성하고 CLI를 시작한다.
    /// 이름이 명시되지 않으면 cliType.rawValue를 기본값으로 사용하며, 중복 시 자동 번호 부여.
    /// 이름이 명시된 경우 중복이면 에러를 반환한다.
    @discardableResult
    func createSession(config: Session.Config) async throws -> Session {
        guard sessions.count < maxConcurrentSessions else {
            throw ManagerError.maxSessionsReached(limit: maxConcurrentSessions)
        }

        // 이름 결정 및 중복 처리
        var resolvedName = config.name ?? config.cliType.rawValue

        if isNameTaken(resolvedName) {
            if config.name != nil {
                // 사용자가 명시적으로 지정한 이름이 중복 → 에러
                throw ManagerError.nameAlreadyTaken(name: resolvedName)
            }
            // 기본 이름 중복 → 자동 번호 부여 (claude-code-2, claude-code-3, ...)
            var suffix = 2
            while isNameTaken("\(resolvedName)-\(suffix)") {
                suffix += 1
            }
            resolvedName = "\(resolvedName)-\(suffix)"
        }

        var finalConfig = config
        finalConfig.name = resolvedName

        // 채널 모드: 포트 충돌 방지 (같은 포트를 사용하는 채널 세션이 있으면 자동 증가)
        if finalConfig.channelEnabled {
            var port = finalConfig.channelPort
            while isChannelPortInUse(port) { port += 1 }
            finalConfig.channelPort = port
        }

        // SDK 모드: 포트 충돌 방지 (채널 포트와도 겹치지 않도록)
        if finalConfig.sdkEnabled {
            var port = finalConfig.sdkPort
            while isBridgePortInUse(port) { port += 1 }
            finalConfig.sdkPort = port
        }

        // Gemini stream 모드: 포트 충돌 방지
        if finalConfig.geminiStreamEnabled {
            var port = finalConfig.geminiStreamPort
            while isBridgePortInUse(port) { port += 1 }
            finalConfig.geminiStreamPort = port
        }

        // Codex app-server 모드: 포트 충돌 방지
        if finalConfig.codexAppServerEnabled {
            var port = finalConfig.codexAppServerPort
            while isBridgePortInUse(port) { port += 1 }
            finalConfig.codexAppServerPort = port
        }

        let session = Session(config: finalConfig)

        // 세션 상태 변화를 SessionManager의 objectWillChange로 전파.
        // DispatchQueue.main.async로 지연하여 SwiftUI 뷰 업데이트 중
        // "Publishing changes from within view updates" 경고를 방지한다.
        // nonisolated(unsafe): Sendable 경고 방지 — MainActor 컨텍스트에서만 접근
        nonisolated(unsafe) let weakSelf = self
        session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { _ in
                DispatchQueue.main.async {
                    weakSelf.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        await MainActor.run {
            sessions[session.id] = session
            sessionOrder.append(session.id)
            if selectedSessionId == nil {
                selectedSessionId = session.id
            }
        }

        // 동일 CLI 타입의 초기화 중인 세션이 있으면 완료될 때까지 대기
        // (동시 시작 시 MCP 서버 등 리소스 충돌 방지)
        while sessions.values.contains(where: {
            $0.id != session.id &&
            $0.status == .initializing &&
            $0.config.cliType == finalConfig.cliType
        }) {
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        // CLI 시작
        try await session.start()

        // 세션 정보 영속화 (종료하지 않은 세션은 앱 재시작 시 복원됨)
        saveToStorage()

        return session
    }

    /// 세션 ID로 조회
    func getSession(id: String) -> Session? {
        sessions[id]
    }

    /// 세션 이름으로 조회 (대소문자 무시, 종료된 세션 제외)
    func getSession(name: String) -> Session? {
        sessions.values.first {
            $0.status != .terminated && $0.name.lowercased() == name.lowercased()
        }
    }

    /// 이름이 활성 세션에서 이미 사용 중인지 확인
    func isNameTaken(_ name: String, excluding sessionId: String? = nil) -> Bool {
        sessions.values.contains { session in
            session.id != sessionId &&
            session.status != .terminated &&
            session.name.lowercased() == name.lowercased()
        }
    }

    /// 세션 이름 변경. 중복 이름이면 에러.
    func renameSession(id: String, newName: String) throws {
        guard let session = sessions[id] else {
            throw ManagerError.sessionNotFound(id: id)
        }
        guard !newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ManagerError.invalidName(reason: "세션 이름은 비어있을 수 없습니다")
        }
        guard !isNameTaken(newName, excluding: id) else {
            throw ManagerError.nameAlreadyTaken(name: newName)
        }
        session.name = newName
    }

    /// 모든 세션 목록
    func listSessions() -> [SessionInfo] {
        sessions.values.map { session in
            SessionInfo(
                id: session.id,
                name: session.name,
                status: session.status,
                cliType: session.config.cliType.rawValue,
                workingDirectory: session.config.workingDirectory,
                createdAt: session.createdAt,
                lastActivity: Date(),
                messageCount: session.messageCount,
                tunnelUrl: session.tunnelURL,
                channelEnabled: session.isChannelMode,
                channelUrl: session.channelServerURL,
                sdkEnabled: session.isSDKMode,
                sdkUrl: session.sdkServerURL,
                bridgeEnabled: session.isBridgeMode,
                bridgeUrl: session.bridgeServerURL
            )
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 세션 종료 및 제거.
    /// 명시적으로 닫은 세션은 영속화에서도 제거된다 (앱 재시작 시 복원 안 됨).
    func deleteSession(id: String) {
        guard let session = sessions[id] else { return }
        session.stop()
        sessions.removeValue(forKey: id)
        sessionOrder.removeAll { $0 == id }

        // 선택된 세션이 삭제되면 다른 세션 선택
        if selectedSessionId == id {
            selectedSessionId = sessions.keys.first
        }

        // 명시적으로 닫은 세션이므로 영속화에서 제거
        saveToStorage()
    }

    /// 사이드바 드래그로 세션 순서 변경.
    func moveSession(from source: IndexSet, to destination: Int) {
        sessionOrder.move(fromOffsets: source, toOffset: destination)
        saveToStorage()
    }

    /// 모든 세션 종료
    func deleteAllSessions() {
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
        sessionOrder.removeAll()
        selectedSessionId = nil
    }

    /// 선택된 세션
    var selectedSession: Session? {
        guard let id = selectedSessionId else { return nil }
        return sessions[id]
    }

    // MARK: - 테스트 지원

    /// 테스트용: CLI 시작 없이 세션을 직접 등록한다.
    /// 프로덕션 코드에서는 반드시 createSession(config:)을 사용할 것.
    func registerSessionForTesting(_ session: Session) {
        sessions[session.id] = session
    }

    /// 테스트용: 세션을 직접 제거한다 (stop() 호출 없이).
    func unregisterSessionForTesting(id: String) {
        sessions.removeValue(forKey: id)
    }

    // MARK: - Channel Server

    /// 해당 포트가 이미 채널 세션에서 사용 중인지 확인
    func isChannelPortInUse(_ port: Int) -> Bool {
        sessions.values.contains {
            $0.status != .terminated && $0.status != .stopped && $0.isChannelMode && $0.config.channelPort == port
        }
    }

    // MARK: - SDK Server

    /// 해당 포트가 이미 SDK 세션에서 사용 중인지 확인
    func isSDKPortInUse(_ port: Int) -> Bool {
        sessions.values.contains {
            $0.status != .terminated && $0.status != .stopped && $0.isSDKMode && $0.config.sdkPort == port
        }
    }

    // MARK: - Gemini Bridge Server

    /// 해당 포트가 이미 Gemini 브릿지 세션에서 사용 중인지 확인
    func isGeminiPortInUse(_ port: Int) -> Bool {
        sessions.values.contains {
            $0.status != .terminated && $0.status != .stopped && $0.isGeminiStreamMode && $0.config.geminiStreamPort == port
        }
    }

    // MARK: - Codex Bridge Server

    /// 해당 포트가 이미 Codex 브릿지 세션에서 사용 중인지 확인
    func isCodexPortInUse(_ port: Int) -> Bool {
        sessions.values.contains {
            $0.status != .terminated && $0.status != .stopped && $0.isCodexAppServerMode && $0.config.codexAppServerPort == port
        }
    }

    /// 해당 포트가 어떤 브릿지 세션에서도 사용 중인지 확인 (포트 충돌 방지용)
    private func isBridgePortInUse(_ port: Int) -> Bool {
        isChannelPortInUse(port) || isSDKPortInUse(port) || isGeminiPortInUse(port) || isCodexPortInUse(port)
    }

    // MARK: - TCC 프리플라이트

    /// 세션 복원 전 작업 디렉토리 접근 권한을 사전 확보한다.
    /// macOS TCC(개인정보 보호)가 보호하는 폴더(Documents, Desktop 등)에 대한
    /// 권한 다이얼로그를 복원 오버레이 표시 전에 처리하여 UX 단절을 방지한다.
    ///
    /// - 이미 권한이 있는 경우: 즉시 반환
    /// - 처음 접근하는 경우: 시스템 다이얼로그 표시 후 사용자 응답을 기다린 뒤 반환
    private func preflightDirectoryAccess(entries: [PersistedSessionEntry]) async {
        // 고유 작업 디렉토리 목록 수집
        let dirs = Set(entries.map { $0.config.workingDirectory })
            .filter { !$0.isEmpty }

        guard !dirs.isEmpty else { return }

        // 백그라운드 스레드에서 디렉토리 접근 시도 (메인 스레드 블록 방지)
        // TCC 다이얼로그는 OS 레벨에서 처리되므로 스레드와 무관하게 정상 표시됨.
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                for dir in dirs {
                    // contentsOfDirectory: TCC 보호 폴더 접근 시 다이얼로그 트리거.
                    // 권한이 이미 있으면 즉시 반환, 없으면 사용자 응답까지 블록.
                    _ = try? FileManager.default.contentsOfDirectory(atPath: dir)
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Cloudflare Tunnel (세션별)

    func startTunnel(sessionId: String) {
        guard let session = sessions[sessionId],
              session.status != .terminated,
              case .idle = session.cloudflare.tunnelState else { return }
        let port = AppConfig.shared.apiPort
        Task { await session.cloudflare.start(port: port) }
    }

    func stopTunnel(sessionId: String) {
        sessions[sessionId]?.cloudflare.stop()
    }
}

// MARK: - Persistence DTO

/// sessions.json 영속화용 래퍼. 세션 설정 + 연결 상태를 함께 저장한다.
struct PersistedSessionEntry: Codable {
    let config: Session.Config
    /// 앱 종료 시점에 연결 중이었는지 여부.
    /// true: 복원 시 자동 연결, false: 메타정보만 복원 (수동 연결 필요)
    let wasConnected: Bool
}

// MARK: - Info DTO

struct SessionInfo: Codable {
    let id: String
    let name: String
    let status: Session.Status
    let cliType: String
    let workingDirectory: String
    let createdAt: Date
    let lastActivity: Date
    let messageCount: Int
    var tunnelUrl: String?
    var channelEnabled: Bool
    var channelUrl: String?
    var sdkEnabled: Bool
    var sdkUrl: String?
    /// 모든 브릿지 모드 포함 (SDK + Gemini Stream + Codex App Server)
    var bridgeEnabled: Bool
    var bridgeUrl: String?
}

// MARK: - Errors

enum ManagerError: LocalizedError {
    case maxSessionsReached(limit: Int)
    case nameAlreadyTaken(name: String)
    case sessionNotFound(id: String)
    case invalidName(reason: String)

    var errorDescription: String? {
        switch self {
        case .maxSessionsReached(let limit):
            return "Maximum concurrent sessions (\(limit)) reached"
        case .nameAlreadyTaken(let name):
            return "Session name '\(name)' is already in use"
        case .sessionNotFound(let id):
            return "Session '\(id)' not found"
        case .invalidName(let reason):
            return reason
        }
    }
}
