import Foundation
import Combine

/// 모든 세션의 생명주기를 관리한다.
/// SwiftUI 뷰와 API 서버 양쪽에서 접근한다.
final class SessionManager: ObservableObject {

    static let shared = SessionManager()

    @Published private(set) var sessions: [String: Session] = [:]
    @Published var selectedSessionId: String? = nil

    var maxConcurrentSessions: Int = 10

    private var cancellables = Set<AnyCancellable>()

    private init() {}

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

        let session = Session(config: finalConfig)

        // 세션 상태 변화를 SessionManager의 objectWillChange로 전파.
        // DispatchQueue.main.async로 지연하여 SwiftUI 뷰 업데이트 중
        // "Publishing changes from within view updates" 경고를 방지한다.
        session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async {
                    self?.objectWillChange.send()
                }
            }
            .store(in: &cancellables)

        await MainActor.run {
            sessions[session.id] = session
            if selectedSessionId == nil {
                selectedSessionId = session.id
            }
        }

        // CLI 시작
        try await session.start()

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
                tunnelUrl: session.tunnelURL
            )
        }.sorted { $0.createdAt < $1.createdAt }
    }

    /// 세션 종료 및 제거
    func deleteSession(id: String) {
        guard let session = sessions[id] else { return }
        session.stop()
        sessions.removeValue(forKey: id)

        // 선택된 세션이 삭제되면 다른 세션 선택
        if selectedSessionId == id {
            selectedSessionId = sessions.keys.first
        }
    }

    /// 모든 세션 종료
    func deleteAllSessions() {
        for session in sessions.values {
            session.stop()
        }
        sessions.removeAll()
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
