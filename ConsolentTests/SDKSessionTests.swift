import XCTest
@testable import Consolent

/// SDK 모드 관련 테스트.
/// Session.Config 기본값, isSDKMode 판정, 포트 충돌 방지, SessionInfo 직렬화를 검증한다.
final class SDKSessionTests: XCTestCase {

    // MARK: - Config 기본값

    func testConfig_sdkDisabledByDefault() {
        let config = Session.Config(workingDirectory: "/tmp")
        XCTAssertFalse(config.sdkEnabled)
        XCTAssertEqual(config.sdkPort, 8788)
        XCTAssertNil(config.sdkModel)
        XCTAssertEqual(config.sdkPermissionMode, "acceptEdits")
    }

    func testConfig_sdkExplicitValues() {
        let config = Session.Config(
            workingDirectory: "/tmp",
            sdkEnabled: true,
            sdkPort: 9999,
            sdkModel: "claude-sonnet-4-20250514",
            sdkPermissionMode: "bypassPermissions"
        )
        XCTAssertTrue(config.sdkEnabled)
        XCTAssertEqual(config.sdkPort, 9999)
        XCTAssertEqual(config.sdkModel, "claude-sonnet-4-20250514")
        XCTAssertEqual(config.sdkPermissionMode, "bypassPermissions")
    }

    // MARK: - isSDKMode

    func testIsSDKMode_claudeCodeEnabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: true)
        let session = Session(config: config)
        XCTAssertTrue(session.isSDKMode)
    }

    func testIsSDKMode_claudeCodeDisabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: false)
        let session = Session(config: config)
        XCTAssertFalse(session.isSDKMode)
    }

    func testIsSDKMode_geminiAlwaysFalse() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .gemini, sdkEnabled: true)
        let session = Session(config: config)
        XCTAssertFalse(session.isSDKMode, "Gemini에서는 sdkEnabled=true여도 isSDKMode=false")
    }

    func testIsSDKMode_codexAlwaysFalse() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .codex, sdkEnabled: true)
        let session = Session(config: config)
        XCTAssertFalse(session.isSDKMode, "Codex에서는 sdkEnabled=true여도 isSDKMode=false")
    }

    // MARK: - sdkServerURL

    func testSDKServerURL_whenEnabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: true, sdkPort: 9999)
        let session = Session(config: config)
        XCTAssertEqual(session.sdkServerURL, "http://localhost:9999")
    }

    func testSDKServerURL_whenDisabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: false)
        let session = Session(config: config)
        XCTAssertNil(session.sdkServerURL)
    }

    func testSDKServerURL_geminiAlwaysNil() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .gemini, sdkEnabled: true, sdkPort: 8788)
        let session = Session(config: config)
        XCTAssertNil(session.sdkServerURL)
    }

    // MARK: - SDK와 Channel 상호 배타

    func testSDKAndChannelIndependent() {
        // 둘 다 활성화해도 각각 독립적으로 동작
        let config = Session.Config(
            workingDirectory: "/tmp",
            cliType: .claudeCode,
            channelEnabled: true,
            sdkEnabled: true
        )
        let session = Session(config: config)
        XCTAssertTrue(session.isChannelMode)
        XCTAssertTrue(session.isSDKMode)
    }

    // MARK: - 포트 충돌 감지

    func testSDKPortInUse_noConflict() {
        let manager = SessionManager.shared

        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: true, sdkPort: 18788)
        let session = Session(id: "sdk_test_1", config: config)
        manager.registerSessionForTesting(session)

        // 다른 포트는 충돌 없음
        XCTAssertFalse(manager.isSDKPortInUse(18789))

        manager.unregisterSessionForTesting(id: "sdk_test_1")
    }

    func testSDKPortInUse_conflict() {
        let manager = SessionManager.shared

        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: true, sdkPort: 18788)
        let session = Session(id: "sdk_test_2", config: config)
        manager.registerSessionForTesting(session)

        // 같은 포트는 충돌
        XCTAssertTrue(manager.isSDKPortInUse(18788))

        manager.unregisterSessionForTesting(id: "sdk_test_2")
    }

    // MARK: - SessionInfo

    func testSessionInfo_sdkFields() {
        let config = Session.Config(
            workingDirectory: "/tmp",
            cliType: .claudeCode,
            sdkEnabled: true,
            sdkPort: 8788
        )
        let session = Session(id: "sdk_test_3", config: config)
        let manager = SessionManager.shared
        manager.registerSessionForTesting(session)

        let infos = manager.listSessions()
        let info = infos.first { $0.id == "sdk_test_3" }

        XCTAssertNotNil(info)
        XCTAssertTrue(info!.sdkEnabled)
        XCTAssertEqual(info!.sdkUrl, "http://localhost:8788")

        manager.unregisterSessionForTesting(id: "sdk_test_3")
    }

    func testSessionInfo_sdkDisabled() {
        let config = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: false)
        let session = Session(id: "sdk_test_4", config: config)
        let manager = SessionManager.shared
        manager.registerSessionForTesting(session)

        let infos = manager.listSessions()
        let info = infos.first { $0.id == "sdk_test_4" }

        XCTAssertNotNil(info)
        XCTAssertFalse(info!.sdkEnabled)
        XCTAssertNil(info!.sdkUrl)

        manager.unregisterSessionForTesting(id: "sdk_test_4")
    }

    // MARK: - CLIAdapter supportsSDKMode

    func testClaudeCodeAdapter_supportsSDK() {
        let adapter = ClaudeCodeAdapter()
        XCTAssertTrue(adapter.supportsSDKMode)
    }

    func testGeminiAdapter_noSDKSupport() {
        let adapter = GeminiAdapter()
        XCTAssertFalse(adapter.supportsSDKMode)
    }

    func testCodexAdapter_noSDKSupport() {
        let adapter = CodexAdapter()
        XCTAssertFalse(adapter.supportsSDKMode)
    }
}
