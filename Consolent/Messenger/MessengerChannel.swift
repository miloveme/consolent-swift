import Foundation
import Vapor

// MARK: - 메신저 채널 타입

/// 지원하는 메신저 플랫폼.
enum MessengerChannelType: String, Codable, CaseIterable, Sendable {
    case telegram
    case whatsapp
    case kakao
    case line
    case imessage

    var displayName: String {
        switch self {
        case .telegram:  return "Telegram"
        case .whatsapp:  return "WhatsApp"
        case .kakao:     return "KakaoTalk"
        case .line:      return "LINE"
        case .imessage:  return "iMessage"
        }
    }

    /// 현재 구현이 완료된 플랫폼인지 여부.
    var isSupported: Bool {
        switch self {
        case .telegram: return true
        case .whatsapp, .kakao, .line, .imessage: return false
        }
    }
}

// MARK: - 메시지 타입

/// 메신저 플랫폼에서 수신한 정규화된 메시지.
struct MessengerMessage: Sendable {
    let botId: String            // 메시지를 수신한 봇 ID
    let channelType: MessengerChannelType
    let chatId: String           // 플랫폼별 채팅/대화방 ID
    let senderId: String         // 발신자 ID
    let senderName: String?      // 표시 이름
    let text: String             // 메시지 텍스트
    let imageURLs: [String]      // 이미지 URL 또는 로컬 경로
    let replyToMessageId: String?
    let rawPayload: Data         // 원본 웹훅 페이로드 (디버깅용)
    let receivedAt: Date
}

/// 메신저 플랫폼으로 전송할 응답.
struct MessengerReply: Sendable {
    let chatId: String
    let text: String
    let replyToMessageId: String?

    init(chatId: String, text: String, replyToMessageId: String? = nil) {
        self.chatId = chatId
        self.text = text
        self.replyToMessageId = replyToMessageId
    }
}

// MARK: - 채널 프로토콜

/// 메신저 플랫폼 커넥터 프로토콜.
/// 각 플랫폼(Telegram, LINE 등)이 이 프로토콜을 구현한다.
/// 하나의 채널 인스턴스가 하나의 봇에 대응한다.
protocol MessengerChannel: AnyObject, Sendable {

    /// 채널 타입 식별자.
    var channelType: MessengerChannelType { get }

    /// 표시용 이름 (예: "Telegram").
    var displayName: String { get }

    /// 채널 활성 상태.
    var isActive: Bool { get }

    /// 플랫폼 메시지 최대 길이. 초과 시 분할 전송.
    var maxMessageLength: Int { get }

    /// Vapor 라우트 등록. MessengerServer 시작 시 1회 호출.
    /// 봇별 고유 라우트를 등록한다 (예: POST /telegram/{botId}).
    func registerRoutes(on router: RoutesBuilder)

    /// 웹훅 인증 검증 (시그니처, 챌린지 등).
    /// 챌린지 응답이 필요하면 Response를 반환, 정상이면 nil.
    func verifyWebhook(request: Request) async throws -> Response?

    /// 웹훅 페이로드를 정규화된 MessengerMessage로 변환.
    /// 사용자 메시지가 아닌 이벤트(상태 업데이트 등)면 nil 반환.
    /// 허용 사용자 검사도 여기서 수행한다.
    func parseWebhook(request: Request) async throws -> MessengerMessage?

    /// 응답 메시지를 플랫폼에 전송.
    func sendReply(_ reply: MessengerReply) async throws

    /// 입력 중(typing) 표시 전송.
    func sendTypingIndicator(chatId: String) async throws

    /// 봇 설정으로 채널을 구성한다.
    func configure(with config: MessengerBotConfig) throws

    /// Polling 시작. 기본 구현: no-op (webhook 전용 채널).
    func startPolling()

    /// Polling 중지.
    func stopPolling()

    /// MessengerServer가 설정하는 메시지 수신 콜백.
    /// 웹훅에서 메시지를 파싱한 후 이 콜백을 통해 MessageDispatcher로 전달.
    var onMessage: (@Sendable (MessengerMessage) async -> Void)? { get set }
}

// MARK: - 프로토콜 기본 구현

extension MessengerChannel {
    func startPolling() {}
    func stopPolling() {}
}

// MARK: - 에러

enum MessengerError: LocalizedError {
    case missingCredential(channel: MessengerChannelType, key: String)
    case webhookVerificationFailed(channel: MessengerChannelType)
    case sessionNotFound(name: String)
    case sessionNotReady(name: String, status: String)
    case sendFailed(channel: MessengerChannelType, reason: String)
    case configLoadFailed(reason: String)
    case channelNotSupported(type: MessengerChannelType)
    case serverAlreadyRunning
    case botNotConnected(botId: String)

    var errorDescription: String? {
        switch self {
        case .missingCredential(let channel, let key):
            return "\(channel.displayName) 채널에 '\(key)' 자격증명이 필요합니다"
        case .webhookVerificationFailed(let channel):
            return "\(channel.displayName) 웹훅 인증 실패"
        case .sessionNotFound(let name):
            return "세션 '\(name)'을 찾을 수 없습니다"
        case .sessionNotReady(let name, let status):
            return "세션 '\(name)'이 준비되지 않았습니다 (상태: \(status))"
        case .sendFailed(let channel, let reason):
            return "\(channel.displayName) 메시지 전송 실패: \(reason)"
        case .configLoadFailed(let reason):
            return "메신저 설정 로드 실패: \(reason)"
        case .channelNotSupported(let type):
            return "\(type.displayName) 채널은 아직 지원되지 않습니다"
        case .serverAlreadyRunning:
            return "메신저 서버가 이미 실행 중입니다"
        case .botNotConnected(let botId):
            return "봇 '\(botId)'에 연결된 세션이 없습니다"
        }
    }
}

// MARK: - 채널 팩토리

/// 채널 타입에 따라 적절한 MessengerChannel 인스턴스를 생성한다.
func createMessengerChannel(type: MessengerChannelType) -> (any MessengerChannel)? {
    switch type {
    case .telegram:
        return TelegramChannel()
    case .whatsapp, .kakao, .line, .imessage:
        // Phase 2+ 에서 구현
        return nil
    }
}
