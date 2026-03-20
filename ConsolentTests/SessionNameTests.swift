import XCTest
@testable import Consolent

/// 세션 이름(model ID) 관련 테스트.
/// Session의 이름 초기화, SessionManager의 이름 기반 조회/중복 체크/rename을 검증한다.
final class SessionNameTests: XCTestCase {

    // MARK: - Session.Config 기본 이름

    func testConfig_defaultNameIsNil() {
        let config = Session.Config(workingDirectory: "/tmp")
        XCTAssertNil(config.name, "기본 name은 nil이어야 함")
    }

    func testConfig_explicitName() {
        let config = Session.Config(name: "my-model", workingDirectory: "/tmp")
        XCTAssertEqual(config.name, "my-model")
    }

    // MARK: - Session 이름 초기화

    func testSession_defaultNameFromCliType_claudeCode() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode)
        let session = Session(config: config)
        XCTAssertEqual(session.name, "claude-code")
    }

    func testSession_defaultNameFromCliType_gemini() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .gemini)
        let session = Session(config: config)
        XCTAssertEqual(session.name, "gemini")
    }

    func testSession_defaultNameFromCliType_codex() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .codex)
        let session = Session(config: config)
        XCTAssertEqual(session.name, "codex")
    }

    func testSession_explicitNameOverridesDefault() {
        let config = Session.Config(name: "my-claude", workingDirectory: "/tmp", cliType: .claudeCode)
        let session = Session(config: config)
        XCTAssertEqual(session.name, "my-claude")
    }

    func testSession_nameIsMutable() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode)
        let session = Session(config: config)
        session.name = "renamed"
        XCTAssertEqual(session.name, "renamed")
    }

    // MARK: - SessionManager 이름 조회 (세션을 직접 등록하여 테스트)

    /// 테스트용 헬퍼: SessionManager에 세션을 직접 등록 (start() 없이)
    private func registerTestSession(name: String, cliType: CLIType = .claudeCode) -> Session {
        let manager = SessionManager.shared
        let config = Session.Config(name: name, workingDirectory: "/tmp", cliType: cliType)
        let session = Session(config: config)
        // @testable import로 접근 가능
        manager.registerSessionForTesting(session)
        return session
    }

    private func cleanupSession(_ session: Session) {
        SessionManager.shared.unregisterSessionForTesting(id: session.id)
    }

    func testGetSessionByName_found() {
        let session = registerTestSession(name: "test-lookup")
        defer { cleanupSession(session) }

        let found = SessionManager.shared.getSession(name: "test-lookup")
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, session.id)
    }

    func testGetSessionByName_caseInsensitive() {
        let session = registerTestSession(name: "MyModel")
        defer { cleanupSession(session) }

        XCTAssertNotNil(SessionManager.shared.getSession(name: "mymodel"), "소문자로도 찾아야 함")
        XCTAssertNotNil(SessionManager.shared.getSession(name: "MYMODEL"), "대문자로도 찾아야 함")
        XCTAssertNotNil(SessionManager.shared.getSession(name: "MyModel"), "원본으로도 찾아야 함")
    }

    func testGetSessionByName_notFound() {
        XCTAssertNil(SessionManager.shared.getSession(name: "nonexistent-model"))
    }

    // MARK: - 이름 중복 체크

    func testIsNameTaken_true() {
        let session = registerTestSession(name: "taken-name")
        defer { cleanupSession(session) }

        XCTAssertTrue(SessionManager.shared.isNameTaken("taken-name"))
        XCTAssertTrue(SessionManager.shared.isNameTaken("Taken-Name"), "대소문자 무시")
    }

    func testIsNameTaken_false() {
        XCTAssertFalse(SessionManager.shared.isNameTaken("available-name"))
    }

    func testIsNameTaken_excludingSelf() {
        let session = registerTestSession(name: "self-check")
        defer { cleanupSession(session) }

        XCTAssertFalse(SessionManager.shared.isNameTaken("self-check", excluding: session.id))
        XCTAssertTrue(SessionManager.shared.isNameTaken("self-check", excluding: "other-id"))
    }

    // MARK: - 세션 이름 변경

    func testRenameSession_success() {
        let session = registerTestSession(name: "old-name")
        defer { cleanupSession(session) }

        XCTAssertNoThrow(try SessionManager.shared.renameSession(id: session.id, newName: "new-name"))
        XCTAssertEqual(session.name, "new-name")
    }

    func testRenameSession_duplicateThrows() {
        let session1 = registerTestSession(name: "name-a")
        let session2 = registerTestSession(name: "name-b")
        defer { cleanupSession(session1); cleanupSession(session2) }

        XCTAssertThrowsError(try SessionManager.shared.renameSession(id: session2.id, newName: "name-a")) { error in
            XCTAssertTrue(error is ManagerError)
        }
    }

    func testRenameSession_emptyNameThrows() {
        let session = registerTestSession(name: "valid-name")
        defer { cleanupSession(session) }

        XCTAssertThrowsError(try SessionManager.shared.renameSession(id: session.id, newName: ""))
        XCTAssertThrowsError(try SessionManager.shared.renameSession(id: session.id, newName: "   "))
    }

    func testRenameSession_notFoundThrows() {
        XCTAssertThrowsError(try SessionManager.shared.renameSession(id: "nonexistent", newName: "anything"))
    }

    // MARK: - SessionInfo에 name 포함

    func testListSessions_includesName() {
        let session = registerTestSession(name: "listed-model")
        defer { cleanupSession(session) }

        let list = SessionManager.shared.listSessions()
        let found = list.first { $0.id == session.id }
        XCTAssertNotNil(found)
        XCTAssertEqual(found?.name, "listed-model")
    }

    // MARK: - ManagerError 메시지

    func testManagerError_nameAlreadyTaken() {
        let error = ManagerError.nameAlreadyTaken(name: "test")
        XCTAssertTrue(error.localizedDescription.contains("test"))
    }

    func testManagerError_sessionNotFound() {
        let error = ManagerError.sessionNotFound(id: "s_abc")
        XCTAssertTrue(error.localizedDescription.contains("s_abc"))
    }

    func testManagerError_invalidName() {
        let error = ManagerError.invalidName(reason: "빈 이름")
        XCTAssertTrue(error.localizedDescription.contains("빈 이름"))
    }
}
