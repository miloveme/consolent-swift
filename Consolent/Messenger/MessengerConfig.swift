import Foundation

// MARK: - 메신저 설정

/// 메신저 봇 전체 설정.
/// `~/Library/Application Support/Consolent/messenger.json`에 영속화.
/// AppConfig과 분리하여 자격증명을 격리한다.
final class MessengerConfig: ObservableObject, Codable {

    @Published var enabled: Bool = false
    @Published var port: Int = 8800
    @Published var bind: String = "127.0.0.1"

    /// 등록된 봇 목록. 같은 플랫폼에서 여러 봇 등록 가능.
    @Published var bots: [MessengerBotConfig] = []

    // MARK: - Codable

    enum CodingKeys: String, CodingKey {
        case enabled, port, bind, bots
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        port = try container.decodeIfPresent(Int.self, forKey: .port) ?? 8800
        bind = try container.decodeIfPresent(String.self, forKey: .bind) ?? "127.0.0.1"
        bots = try container.decodeIfPresent([MessengerBotConfig].self, forKey: .bots) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(port, forKey: .port)
        try container.encode(bind, forKey: .bind)
        try container.encode(bots, forKey: .bots)
    }

    // MARK: - 영속화

    private static var configURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Consolent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("messenger.json")
    }

    /// messenger.json에서 설정을 로드한다. 파일이 없으면 기본값 반환.
    static func load() -> MessengerConfig {
        let url = configURL
        guard let data = try? Data(contentsOf: url) else {
            return MessengerConfig()
        }
        let decoder = JSONDecoder()
        guard let config = try? decoder.decode(MessengerConfig.self, from: data) else {
            print("[MessengerConfig] messenger.json 파싱 실패, 기본값 사용")
            return MessengerConfig()
        }
        return config
    }

    /// 현재 설정을 messenger.json에 저장한다.
    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: Self.configURL, options: .atomic)
    }

    /// 봇 ID로 설정을 조회한다.
    func botConfig(id: String) -> MessengerBotConfig? {
        bots.first { $0.id == id }
    }

    /// 특정 채널 타입의 봇 목록을 반환한다.
    func botConfigs(for channelType: MessengerChannelType) -> [MessengerBotConfig] {
        bots.filter { $0.channelType == channelType }
    }

    /// 특정 세션 이름에 연결된 봇 목록을 반환한다.
    func botsForSession(name: String) -> [MessengerBotConfig] {
        bots.filter { $0.targetSessionName?.lowercased() == name.lowercased() }
    }

    /// 봇 설정을 업데이트하거나 추가한다.
    func setBotConfig(_ config: MessengerBotConfig) {
        if let idx = bots.firstIndex(where: { $0.id == config.id }) {
            bots[idx] = config
        } else {
            bots.append(config)
        }
    }

    /// 봇을 삭제한다.
    func removeBot(id: String) {
        bots.removeAll { $0.id == id }
    }
}

// MARK: - 봇 설정

/// 개별 메신저 봇 설정.
/// 같은 플랫폼에서 여러 봇을 등록할 수 있다 (예: Telegram 봇 2개).
struct MessengerBotConfig: Codable, Identifiable, Sendable {
    /// 봇 고유 ID (자동 생성).
    var id: String

    /// 사용자가 지정하는 봇 표시 이름 (예: "코딩 봇").
    var name: String = ""

    /// 메신저 플랫폼 타입.
    var channelType: MessengerChannelType

    /// 활성 여부.
    var enabled: Bool = false

    /// 이 봇이 연결된 세션 이름. nil이면 미연결.
    var targetSessionName: String? = nil

    /// 플랫폼별 자격증명 (토큰, 시크릿 등).
    /// Telegram: botToken, webhookSecret
    /// WhatsApp: accessToken, verifyToken, phoneNumberId, appSecret
    /// LINE: channelAccessToken, channelSecret
    /// KakaoTalk: appKey, botId
    var credentials: [String: String] = [:]

    /// 허용 사용자 ID 목록. 빈 배열이면 모든 사용자 허용.
    var allowedUserIds: [String] = []

    /// 이 봇 메시지에 자동 추가되는 시스템 프롬프트.
    var systemPrompt: String? = nil

    /// 유지할 대화 히스토리 턴 수 (0이면 히스토리 없음).
    var maxHistoryTurns: Int = 10

    /// 응답 타임아웃 (초).
    var responseTimeout: Int = 300

    init(channelType: MessengerChannelType) {
        self.id = String(UUID().uuidString.prefix(8).lowercased())
        self.channelType = channelType
    }

    enum CodingKeys: String, CodingKey {
        case id, name
        case channelType = "channel_type"
        case enabled
        case targetSessionName = "target_session_name"
        case credentials
        case allowedUserIds = "allowed_user_ids"
        case systemPrompt = "system_prompt"
        case maxHistoryTurns = "max_history_turns"
        case responseTimeout = "response_timeout"
    }
}
