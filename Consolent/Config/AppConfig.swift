import Foundation

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
    @Published var defaultCwd: String = NSHomeDirectory()
    @Published var defaultShell: String = "/bin/zsh"
    @Published var promptPattern: String = "^> $"

    // MARK: - Terminal

    @Published var fontFamily: String = "SF Mono"
    @Published var fontSize: Int = 13
    @Published var theme: String = "dark"
    @Published var scrollbackLines: Int = 10000

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case apiEnabled, apiPort, apiBind, apiKey, includeRawOutput
        case maxConcurrentSessions, sessionIdleTimeout, outputBufferMB
        case defaultCliType, claudePath, defaultCwd, defaultShell, promptPattern
        case fontFamily, fontSize, theme, scrollbackLines
    }

    init() {
        if apiKey.isEmpty {
            apiKey = Self.generateKey()
        }
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
        defaultShell = try c.decodeIfPresent(String.self, forKey: .defaultShell) ?? "/bin/zsh"
        promptPattern = try c.decodeIfPresent(String.self, forKey: .promptPattern) ?? "^> $"
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? "SF Mono"
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize) ?? 13
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? "dark"
        scrollbackLines = try c.decodeIfPresent(Int.self, forKey: .scrollbackLines) ?? 10000
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
        try c.encode(defaultShell, forKey: .defaultShell)
        try c.encode(promptPattern, forKey: .promptPattern)
        try c.encode(fontFamily, forKey: .fontFamily)
        try c.encode(fontSize, forKey: .fontSize)
        try c.encode(theme, forKey: .theme)
        try c.encode(scrollbackLines, forKey: .scrollbackLines)
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
