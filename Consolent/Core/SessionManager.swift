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

    /// 새 세션을 생성하고 Claude Code를 시작한다.
    @discardableResult
    func createSession(config: Session.Config) async throws -> Session {
        guard sessions.count < maxConcurrentSessions else {
            throw ManagerError.maxSessionsReached(limit: maxConcurrentSessions)
        }

        let session = Session(config: config)

        // 상태 변화 관찰
        session.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        await MainActor.run {
            sessions[session.id] = session
            if selectedSessionId == nil {
                selectedSessionId = session.id
            }
        }

        // Claude Code 시작
        try await session.start()

        return session
    }

    /// 세션 조회
    func getSession(id: String) -> Session? {
        sessions[id]
    }

    /// 모든 세션 목록
    func listSessions() -> [SessionInfo] {
        sessions.values.map { session in
            SessionInfo(
                id: session.id,
                status: session.status,
                cliType: session.config.cliType.rawValue,
                workingDirectory: session.config.workingDirectory,
                createdAt: session.createdAt,
                lastActivity: Date(),
                messageCount: session.messageCount
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
}

// MARK: - Info DTO

struct SessionInfo: Codable {
    let id: String
    let status: Session.Status
    let cliType: String
    let workingDirectory: String
    let createdAt: Date
    let lastActivity: Date
    let messageCount: Int
}

// MARK: - Errors

enum ManagerError: LocalizedError {
    case maxSessionsReached(limit: Int)

    var errorDescription: String? {
        switch self {
        case .maxSessionsReached(let limit):
            return "Maximum concurrent sessions (\(limit)) reached"
        }
    }
}
