import XCTest
@testable import Consolent

/// 세션 복원 원자성 테스트.
/// hasSameEffectiveConfig 비교 로직과 restoreFromStorage 충돌 처리를 검증한다.
final class SessionRestoreTests: XCTestCase {

    private var manager: SessionManager!
    private var tempURL: URL!

    override func setUp() {
        super.setUp()
        manager = SessionManager.shared
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("consolent_test_sessions_\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempURL)
        // 테스트에서 등록한 세션 정리
        for session in manager.sessions.values where session.id.hasPrefix("restore_test_") {
            manager.unregisterSessionForTesting(id: session.id)
        }
        super.tearDown()
    }

    // MARK: - hasSameEffectiveConfig

    func testSameEffectiveConfig_identical() {
        let a = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode)
        let b = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode)
        XCTAssertTrue(a.hasSameEffectiveConfig(as: b))
    }

    func testSameEffectiveConfig_differentCliType() {
        let a = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode)
        let b = Session.Config(workingDirectory: "/tmp", cliType: .gemini)
        XCTAssertFalse(a.hasSameEffectiveConfig(as: b))
    }

    func testSameEffectiveConfig_differentWorkingDirectory() {
        let a = Session.Config(workingDirectory: "/tmp/foo", cliType: .claudeCode)
        let b = Session.Config(workingDirectory: "/tmp/bar", cliType: .claudeCode)
        XCTAssertFalse(a.hasSameEffectiveConfig(as: b))
    }

    func testSameEffectiveConfig_differentSDKPort() {
        let a = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: true, sdkPort: 8788)
        let b = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: true, sdkPort: 9999)
        XCTAssertFalse(a.hasSameEffectiveConfig(as: b))
    }

    func testSameEffectiveConfig_differentSDKEnabled() {
        let a = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: false)
        let b = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, sdkEnabled: true)
        XCTAssertFalse(a.hasSameEffectiveConfig(as: b))
    }

    func testSameEffectiveConfig_differentChannelPort() {
        let a = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: true, channelPort: 8787)
        let b = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode, channelEnabled: true, channelPort: 9000)
        XCTAssertFalse(a.hasSameEffectiveConfig(as: b))
    }

    func testSameEffectiveConfig_differentGeminiPort() {
        let a = Session.Config(workingDirectory: "/tmp", cliType: .gemini, geminiStreamEnabled: true, geminiStreamPort: 8789)
        let b = Session.Config(workingDirectory: "/tmp", cliType: .gemini, geminiStreamEnabled: true, geminiStreamPort: 9001)
        XCTAssertFalse(a.hasSameEffectiveConfig(as: b))
    }

    func testSameEffectiveConfig_nameIgnored() {
        // name은 비교에서 제외 — 이름은 lookup key로만 사용
        var a = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode)
        a.name = "my-session"
        var b = Session.Config(workingDirectory: "/tmp", cliType: .claudeCode)
        b.name = "other-name"
        XCTAssertTrue(a.hasSameEffectiveConfig(as: b))
    }

    // MARK: - restoreFromStorage: 신규 세션 복원

    func testRestore_newSessions_areCreated() async throws {
        let config = makeConfig(name: "restore_test_new", cliType: .claudeCode)
        try writeEntries([PersistedSessionEntry(config: config, wasConnected: false)], to: tempURL)

        let before = manager.sessions.count
        await manager.restoreFromStorage(from: tempURL, conflictResolver: { _, _, _ in false })
        let after = manager.sessions.count

        XCTAssertEqual(after, before + 1)
        XCTAssertNotNil(manager.getSession(name: "restore_test_new"))

        manager.getSession(name: "restore_test_new").map { manager.unregisterSessionForTesting(id: $0.id) }
    }

    // MARK: - restoreFromStorage: 동일 설정 세션 skip

    func testRestore_identicalSession_isSkipped() async throws {
        let config = makeConfig(name: "restore_test_skip", cliType: .claudeCode)
        let existing = Session(id: "restore_test_skip_id", config: config)
        manager.registerSessionForTesting(existing)

        try writeEntries([PersistedSessionEntry(config: config, wasConnected: false)], to: tempURL)

        let before = manager.sessions.count
        await manager.restoreFromStorage(from: tempURL, conflictResolver: { _, _, _ in
            XCTFail("동일 설정이면 resolver가 호출되면 안 됨")
            return false
        })
        let after = manager.sessions.count

        XCTAssertEqual(after, before, "동일 설정 세션은 추가되지 않아야 함")
        manager.unregisterSessionForTesting(id: "restore_test_skip_id")
    }

    // MARK: - restoreFromStorage: 충돌 → 건너뛰기

    func testRestore_conflictingSession_skip() async throws {
        var existingConfig = makeConfig(name: "restore_test_conflict", cliType: .claudeCode)
        existingConfig.sdkPort = 8788
        let existing = Session(id: "restore_test_conflict_id", config: existingConfig)
        manager.registerSessionForTesting(existing)

        var storedConfig = makeConfig(name: "restore_test_conflict", cliType: .claudeCode)
        storedConfig.sdkPort = 9999  // 포트가 다름
        try writeEntries([PersistedSessionEntry(config: storedConfig, wasConnected: false)], to: tempURL)

        var resolverCalled = false
        await manager.restoreFromStorage(from: tempURL, conflictResolver: { name, _, _ in
            resolverCalled = true
            XCTAssertEqual(name, "restore_test_conflict")
            return false  // 건너뛰기 선택
        })

        XCTAssertTrue(resolverCalled, "충돌 시 resolver가 호출되어야 함")
        // 기존 세션이 그대로 유지되어야 함
        XCTAssertEqual(manager.getSession(name: "restore_test_conflict")?.id, "restore_test_conflict_id")
        manager.unregisterSessionForTesting(id: "restore_test_conflict_id")
    }

    // MARK: - restoreFromStorage: 충돌 → 대치

    func testRestore_conflictingSession_replace() async throws {
        var existingConfig = makeConfig(name: "restore_test_replace", cliType: .claudeCode)
        existingConfig.sdkPort = 8788
        let existing = Session(id: "restore_test_replace_id", config: existingConfig)
        manager.registerSessionForTesting(existing)

        var storedConfig = makeConfig(name: "restore_test_replace", cliType: .claudeCode)
        storedConfig.sdkPort = 9999  // 포트가 다름
        storedConfig.sdkEnabled = true
        try writeEntries([PersistedSessionEntry(config: storedConfig, wasConnected: false)], to: tempURL)

        await manager.restoreFromStorage(from: tempURL, conflictResolver: { _, _, _ in
            return true  // 대치 선택
        })

        // 기존 세션이 제거되고 저장된 설정의 세션이 등록되어야 함
        let restored = manager.getSession(name: "restore_test_replace")
        XCTAssertNotNil(restored)
        XCTAssertNotEqual(restored?.id, "restore_test_replace_id", "기존 세션 ID가 아니어야 함")
        XCTAssertEqual(restored?.config.sdkPort, 9999)

        if let id = restored?.id { manager.unregisterSessionForTesting(id: id) }
    }

    // MARK: - restoreFromStorage: 복원 후 saveToStorage 동기화

    func testRestore_savesAfterRestore() async throws {
        let config = makeConfig(name: "restore_test_save", cliType: .claudeCode)
        try writeEntries([PersistedSessionEntry(config: config, wasConnected: false)], to: tempURL)

        await manager.restoreFromStorage(from: tempURL, conflictResolver: { _, _, _ in false })

        // sessions.json이 업데이트되었는지 확인 (타임스탬프 비교)
        let attrs = try FileManager.default.attributesOfItem(atPath: Self.productionStoreURL().path)
        let modDate = attrs[.modificationDate] as? Date
        XCTAssertNotNil(modDate)
        XCTAssertLessThanOrEqual(Date().timeIntervalSince(modDate!), 5.0, "복원 후 5초 내에 저장되어야 함")

        manager.getSession(name: "restore_test_save").map { manager.unregisterSessionForTesting(id: $0.id) }
    }

    // MARK: - Helpers

    private func makeConfig(name: String, cliType: CLIType) -> Session.Config {
        var config = Session.Config(workingDirectory: "/tmp", cliType: cliType)
        config.name = name
        return config
    }

    private func writeEntries(_ entries: [PersistedSessionEntry], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(entries)
        try data.write(to: url)
    }

    private static func productionStoreURL() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Consolent/sessions.json")
    }
}
