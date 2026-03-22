import XCTest
@testable import Consolent

/// 채널 서버 모드 관련 테스트.
/// Session.Config 기본값, isChannelMode 판정, 포트 충돌 방지, 라우팅 제외를 검증한다.
final class ChannelModeTests: XCTestCase {

    // MARK: - Config 기본값

    func testConfig_channelDisabledByDefault() {
        let config = Session.Config(workingDirectory: "/tmp")
        XCTAssertFalse(config.channelEnabled)
        XCTAssertEqual(config.channelPort, 8787)
        XCTAssertEqual(config.channelServerName, "openai-compat")
    }

    func testConfig_channelExplicitValues() {
        let config = Session.Config(
            workingDirectory: "/tmp",
            channelEnabled: true,
            channelPort: 9090,
            channelServerName: "my-server"
        )
        XCTAssertTrue(config.channelEnabled)
        XCTAssertEqual(config.channelPort, 9090)
        XCTAssertEqual(config.channelServerName, "my-server")
    }

    // MARK: - isChannelMode

    func testIsChannelMode_claudeCodeEnabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: true)
        let session = Session(config: config)
        XCTAssertTrue(session.isChannelMode)
    }

    func testIsChannelMode_claudeCodeDisabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: false)
        let session = Session(config: config)
        XCTAssertFalse(session.isChannelMode)
    }

    func testIsChannelMode_geminiAlwaysFalse() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .gemini, channelEnabled: true)
        let session = Session(config: config)
        XCTAssertFalse(session.isChannelMode, "Gemini에서는 channelEnabled=true여도 isChannelMode=false")
    }

    func testIsChannelMode_codexAlwaysFalse() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .codex, channelEnabled: true)
        let session = Session(config: config)
        XCTAssertFalse(session.isChannelMode, "Codex에서는 channelEnabled=true여도 isChannelMode=false")
    }

    // MARK: - channelServerURL

    func testChannelServerURL_whenEnabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: true, channelPort: 9999)
        let session = Session(config: config)
        XCTAssertEqual(session.channelServerURL, "http://localhost:9999")
    }

    func testChannelServerURL_whenDisabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: false)
        let session = Session(config: config)
        XCTAssertNil(session.channelServerURL)
    }

    func testChannelServerURL_geminiAlwaysNil() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .gemini, channelEnabled: true, channelPort: 8787)
        let session = Session(config: config)
        XCTAssertNil(session.channelServerURL)
    }

    // MARK: - 포트 충돌 감지

    func testChannelPortInUse_noConflict() {
        let manager = SessionManager.shared

        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: true, channelPort: 18787)
        let session = Session(config: config)
        manager.registerSessionForTesting(session)
        defer { manager.unregisterSessionForTesting(id: session.id) }

        // 다른 포트는 사용 중이 아님
        XCTAssertFalse(manager.isChannelPortInUse(18788))
    }

    func testChannelPortInUse_conflict() {
        let manager = SessionManager.shared

        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: true, channelPort: 18787)
        let session = Session(config: config)
        manager.registerSessionForTesting(session)
        defer { manager.unregisterSessionForTesting(id: session.id) }

        XCTAssertTrue(manager.isChannelPortInUse(18787))
    }

    func testChannelPortInUse_nonChannelSessionIgnored() {
        let manager = SessionManager.shared

        // 채널 비활성 세션은 포트 충돌에 포함되지 않음
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: false, channelPort: 18787)
        let session = Session(config: config)
        manager.registerSessionForTesting(session)
        defer { manager.unregisterSessionForTesting(id: session.id) }

        XCTAssertFalse(manager.isChannelPortInUse(18787))
    }

    // MARK: - SessionInfo 채널 필드

    func testSessionInfo_channelFields() {
        let manager = SessionManager.shared

        let config = Session.Config(
            name: "ch-test",
            workingDirectory: "/tmp",
            cliType: .claudeCode,
            channelEnabled: true,
            channelPort: 18888
        )
        let session = Session(config: config)
        manager.registerSessionForTesting(session)
        defer { manager.unregisterSessionForTesting(id: session.id) }

        let infos = manager.listSessions()
        let info = infos.first { $0.id == session.id }
        XCTAssertNotNil(info)
        XCTAssertTrue(info!.channelEnabled)
        XCTAssertEqual(info!.channelUrl, "http://localhost:18888")
    }

    func testSessionInfo_nonChannelFields() {
        let manager = SessionManager.shared

        let config = Session.Config(name: "nch-test", workingDirectory: "/tmp", cliType: .claudeCode)
        let session = Session(config: config)
        manager.registerSessionForTesting(session)
        defer { manager.unregisterSessionForTesting(id: session.id) }

        let infos = manager.listSessions()
        let info = infos.first { $0.id == session.id }
        XCTAssertNotNil(info)
        XCTAssertFalse(info!.channelEnabled)
        XCTAssertNil(info!.channelUrl)
    }
}
