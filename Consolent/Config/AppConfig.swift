import Foundation
import Combine

/// 앱 설정. JSON 파일로 영속화.
final class AppConfig: ObservableObject, Codable {

    static let shared = AppConfig.load()

    // MARK: - API Server

    @Published var apiEnabled: Bool = true
    @Published var apiPort: Int = 9999
    @Published var apiBind: String = "127.0.0.1"
    @Published var apiKey: String = ""
    @Published var includeRawOutput: Bool = false

    // MARK: - Sessions

    @Published var maxConcurrentSessions: Int = 10
    @Published var sessionIdleTimeout: Int = 3600
    @Published var outputBufferMB: Int = 10

    // MARK: - CLI Tool

    @Published var defaultCliType: CLIType = .claudeCode
    @Published var claudePath: String = "claude"  // 하위 호환용 유지
    @Published var defaultCwd: String = NSHomeDirectory()  // 하위 호환용 유지
    /// CLI 도구별 작업 디렉토리. 미설정 시 defaultCwd 사용.
    @Published var cwdPerCliType: [String: String] = [:]
    @Published var defaultShell: String = "/bin/zsh"
    @Published var promptPattern: String = "^> $"

    /// 지정된 CLI 타입의 작업 디렉토리를 반환한다.
    /// CLI별 설정이 없으면 defaultCwd를 반환.
    func cwd(for cliType: CLIType) -> String {
        cwdPerCliType[cliType.rawValue] ?? defaultCwd
    }

    /// 지정된 CLI 타입의 작업 디렉토리를 설정한다.
    func setCwd(_ path: String, for cliType: CLIType) {
        cwdPerCliType[cliType.rawValue] = path
    }

    // MARK: - SDK Mode

    /// SDK 브릿지 Python 가상환경 경로.
    /// 기본값: ~/Library/Application Support/Consolent/sdk-venv
    @Published var sdkVenvPath: String = AppConfig.defaultSDKVenvPath

    /// 브릿지 서버 출력 레벨.
    /// "error": 오류만 / "info": 상태 메시지(기본) / "debug": 원시 출력 포함
    @Published var bridgeLogLevel: String = "info"

    /// Agent/브릿지 모드 세션에 대한 요청을 Consolent이 투명하게 프록시할지 여부.
    /// false(기본): 410 Gone + 브릿지 URL 안내 (클라이언트가 직접 연결)
    /// true: Consolent이 브릿지 서버로 요청을 포워딩 (단일 엔드포인트)
    @Published var proxyBridgeRequests: Bool = false

    static let defaultSDKVenvPath: String = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Consolent/sdk-venv").path
    }()

    // MARK: - Terminal

    @Published var fontFamily: String = "SF Mono"
    @Published var fontSize: Int = 13
    @Published var theme: String = "dark"
    @Published var scrollbackLines: Int = 1000
    /// Headless 터미널 행 수. TUI 앱은 alternate screen buffer(스크롤백 없음)를 사용하므로,
    /// 긴 응답의 마커(⏺/✦)가 화면에 남도록 충분히 큰 값을 설정한다.
    @Published var headlessTerminalRows: Int = 500

    // MARK: - App Behavior

    /// 시작 시 메뉴바 모드로 실행 (윈도우 숨김)
    @Published var launchToMenuBar: Bool = false

    /// 자동 강제 복구 모드.
    /// ON: 포트 충돌 등 시작 오류 발생 시 확인 없이 기존 프로세스를 강제 종료하고 자동 재시작.
    /// OFF(기본): 충돌 정보 표시 후 사용자가 직접 해결 선택.
    @Published var autoForceRecovery: Bool = false

    // MARK: - Debug

    /// 로그 레벨: "off", "fatal", "info", "debug"
    @Published var logLevel: String = "off"
    /// 디버그 로그 보관 기간 (일)
    @Published var debugLogRetentionDays: Int = 7
    /// 로그 파일 최대 크기 (MB). 초과 시 새 파일로 분할.
    @Published var debugLogMaxFileSizeMB: Int = 50

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case apiEnabled, apiPort, apiBind, apiKey, includeRawOutput
        case maxConcurrentSessions, sessionIdleTimeout, outputBufferMB
        case defaultCliType, claudePath, defaultCwd, cwdPerCliType, defaultShell, promptPattern
        case fontFamily, fontSize, theme, scrollbackLines, headlessTerminalRows
        case launchToMenuBar
        case autoForceRecovery
        case sdkVenvPath
        case bridgeLogLevel
        case proxyBridgeRequests
        case logLevel, debugLogRetentionDays, debugLogMaxFileSizeMB
    }

    /// 자동 저장 구독. Published 속성 변경 시 JSON 파일에 저장한다.
    private var autoSaveCancellable: AnyCancellable?

    init() {
        if apiKey.isEmpty {
            apiKey = Self.generateKey()
        }
        setupAutoSave()
    }

    required init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiEnabled = try c.decodeIfPresent(Bool.self, forKey: .apiEnabled) ?? true
        apiPort = try c.decodeIfPresent(Int.self, forKey: .apiPort) ?? 9999
        apiBind = try c.decodeIfPresent(String.self, forKey: .apiBind) ?? "127.0.0.1"
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? Self.generateKey()
        includeRawOutput = try c.decodeIfPresent(Bool.self, forKey: .includeRawOutput) ?? false
        maxConcurrentSessions = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentSessions) ?? 10
        sessionIdleTimeout = try c.decodeIfPresent(Int.self, forKey: .sessionIdleTimeout) ?? 3600
        outputBufferMB = try c.decodeIfPresent(Int.self, forKey: .outputBufferMB) ?? 10
        defaultCliType = try c.decodeIfPresent(CLIType.self, forKey: .defaultCliType) ?? .claudeCode
        claudePath = try c.decodeIfPresent(String.self, forKey: .claudePath) ?? "claude"
        defaultCwd = try c.decodeIfPresent(String.self, forKey: .defaultCwd) ?? NSHomeDirectory()
        cwdPerCliType = try c.decodeIfPresent([String: String].self, forKey: .cwdPerCliType) ?? [:]
        defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell) ?? "/bin/zsh"
        promptPattern = try c.decodeIfPresent(String.self, forKey: .promptPattern) ?? "^> $"
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "SF Mono"
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 13
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "dark"
        scrollbackLines = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 1000
        headlessTerminalRows = try c.decodeIfPresent(Int.self, forKey: .headlessTerminalRows) ?? 500
        launchToMenuBar = try c.decodeIfPresent(Bool.self, forKey: .launchToMenuBar) ?? false
        autoForceRecovery = try c.decodeIfPresent(Bool.self, forKey: .autoForceRecovery) ?? false
        sdkVenvPath = try c.decodeIfPresent(String.self, forKey: .sdkVenvPath) ?? Self.defaultSDKVenvPath
        bridgeLogLevel = try c.decodeIfPresent(String.self, forKey: .bridgeLogLevel) ?? "info"
        proxyBridgeRequests = try c.decodeIfPresent(Bool.self, forKey: .proxyBridgeRequests) ?? false
        logLevel = try c.decodeIfPresent(String.self, forKey: .logLevel) ?? "off"
        debugLogRetentionDays = try c.decodeIfPresent(Int.self, forKey: .debugLogRetentionDays) ?? 7
        debugLogMaxFileSizeMB = try c.decodeIfPresent(Int.self, forKey: .debugLogMaxFileSizeMB) ?? 50
        setupAutoSave()
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(apiEnabled, forKey: .apiEnabled)
        try c.encode(apiPort, forKey: .apiPort)
        try c.encode(apiBind, forKey: .apiBind)
        try c.encode(apiKey, forKey: .apiKey)
        try c.encode(includeRawOutput, forKey: .includeRawOutput)
        try c.encode(maxConcurrentSessions, forKey: .maxConcurrentSessions)
        try c.encode(sessionIdleTimeout, forKey: .sessionIdleTimeout)
        try c.encode(outputBufferMB, forKey: .outputBufferMB)
        try c.encode(defaultCliType, forKey: .defaultCliType)
        try c.encode(claudePath, forKey: .claudePath)
        try c.encode(defaultCwd, forKey: .defaultCwd)
        try c.encode(cwdPerCliType, forKey: .cwdPerCliType)
        try c.encode(defaultShell, forKey: .defaultShell)
        try c.encode(promptPattern, forKey: .promptPattern)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(theme, forKey: .theme)
        try c.encode(scrollbackLines, forKey: .scrollbackLines)
        try c.encode(headlessTerminalRows, forKey: .headlessTerminalRows)
        try c.encode(launchToMenuBar, forKey: .launchToMenuBar)
        try c.encode(autoForceRecovery, forKey: .autoForceRecovery)
        try c.encode(sdkVenvPath, forKey: .sdkVenvPath)
        try c.encode(bridgeLogLevel, forKey: .bridgeLogLevel)
        try c.encode(proxyBridgeRequests, forKey: .proxyBridgeRequests)
        try c.encode(logLevel, forKey: .logLevel)
        try c.encode(debugLogRetentionDays, forKey: .debugLogRetentionDays)
        try c.encode(debugLogMaxFileSizeMB, forKey: .debugLogMaxFileSizeMB)
    }

    /// Published 속성 변경 시 자동으로 JSON 파일에 저장.
    /// debounce 0.5초 + 백그라운드 큐 저장으로 뷰 업데이트 사이클과 충돌하지 않는다.
    private func setupAutoSave() {
        autoSaveCancellable = objectWillChange
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.global(qos: .utility))
            .sink { [weak self] _ in
                self?.save()
            }
    }

    // MARK: - Persistence

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Consolent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configURL),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data) else {
            let config = AppConfig()
            config.save()
            return config
        }
        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }

    func regenerateKey() {
        apiKey = Self.generateKey()
        save()
    }

    private static func generateKey() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: 0...255) }
        let base64 = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "")
            .replacingOccurrences(of: "/", with: "")
            .replacingOccurrences(of: "=", with: "")
        return "cst_\(String(base64.prefix(32)))"
    }
}
