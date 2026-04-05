import Foundation
import Vapor

/// Telegram Bot API 채널 구현.
/// 기본: Polling (getUpdates long polling) — 터널 불필요.
/// 옵션: Webhook — public URL(Cloudflare 터널 등) 설정 시 사용.
final class TelegramChannel: MessengerChannel, @unchecked Sendable {

    let channelType: MessengerChannelType = .telegram
    let displayName = "Telegram"
    let maxMessageLength = 4096

    private(set) var isActive = false
    var onMessage: (@Sendable (MessengerMessage) async -> Void)?

    private var botId: String = ""
    private var botToken: String = ""
    private var webhookSecret: String = ""
    private var allowedUserIds: Set<String> = []

    /// Polling 태스크
    private var pollingTask: Task<Void, Never>?

    /// Telegram Bot API base URL
    private var apiBaseURL: String { "https://api.telegram.org/bot\(botToken)" }

    // MARK: - 설정

    func configure(with config: MessengerBotConfig) throws {
        guard let token = config.credentials["botToken"], !token.isEmpty else {
            throw MessengerError.missingCredential(channel: .telegram, key: "botToken")
        }
        botId = config.id
        botToken = token
        webhookSecret = config.credentials["webhookSecret"] ?? ""
        allowedUserIds = Set(config.allowedUserIds)
        isActive = true
    }

    // MARK: - Polling (기본 모드)

    /// Polling 시작. getUpdates long polling으로 메시지를 수신한다.
    /// 터널 없이 즉시 동작. Webhook이 등록되면 Telegram이 자동으로 getUpdates를 비움.
    func startPolling() {
        guard pollingTask == nil else { return }

        // Polling 시작 전 webhook 해제 (이전에 등록된 webhook이 있으면 polling이 동작하지 않음)
        let capturedApiBase = apiBaseURL
        let capturedBotId = botId

        pollingTask = Task { [weak self] in
            // webhook 해제
            if let deleteURL = URL(string: "\(capturedApiBase)/deleteWebhook") {
                var req = URLRequest(url: deleteURL)
                req.httpMethod = "POST"
                _ = try? await URLSession.shared.data(for: req)
            }

            print("[TelegramChannel:\(capturedBotId)] Polling 시작")

            var offset: Int64 = 0

            while !Task.isCancelled {
                guard let self else { break }

                do {
                    // long polling: timeout=30초 (30초간 대기하다 새 메시지 오면 즉시 반환)
                    guard let url = URL(string: "\(capturedApiBase)/getUpdates?offset=\(offset)&timeout=30") else {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }

                    var request = URLRequest(url: url)
                    request.timeoutInterval = 35 // long polling timeout + 여유

                    let (data, response) = try await URLSession.shared.data(for: request)

                    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let ok = json["ok"] as? Bool, ok,
                          let updates = json["result"] as? [[String: Any]] else {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                        continue
                    }

                    for update in updates {
                        // offset 업데이트 (처리 완료 확인)
                        if let updateId = update["update_id"] as? Int64 {
                            offset = updateId + 1
                        }

                        // update → MessengerMessage 변환
                        if let message = await self.parseUpdate(update) {
                            let capturedMessage = message
                            let capturedCallback = self.onMessage
                            // 디스패치 (polling은 비동기 처리 필요 없음 — 이미 별도 Task)
                            await capturedCallback?(capturedMessage)
                        }
                    }
                } catch is CancellationError {
                    break
                } catch {
                    // 네트워크 에러 시 잠시 대기 후 재시도
                    if !Task.isCancelled {
                        print("[TelegramChannel:\(capturedBotId)] Polling 에러: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                    }
                }
            }

            print("[TelegramChannel:\(capturedBotId)] Polling 종료")
        }
    }

    /// Polling 중지.
    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Webhook 라우트 (옵션)

    func registerRoutes(on router: RoutesBuilder) {
        let capturedBotId = botId
        router.post("telegram", PathComponent(stringLiteral: capturedBotId)) { [self] req -> Response in
            if let verifyResponse = try await verifyWebhook(request: req) {
                return verifyResponse
            }

            guard let message = try await parseWebhook(request: req) else {
                return Response(status: .ok)
            }

            let capturedMessage = message
            let capturedCallback = onMessage
            Task {
                await capturedCallback?(capturedMessage)
            }

            return Response(status: .ok)
        }
    }

    func verifyWebhook(request: Request) async throws -> Response? {
        if !webhookSecret.isEmpty {
            guard let header = request.headers.first(name: "X-Telegram-Bot-Api-Secret-Token"),
                  header == webhookSecret else {
                return Response(status: .unauthorized)
            }
        }
        return nil
    }

    /// Webhook 요청 파싱 (Vapor Request → MessengerMessage).
    func parseWebhook(request: Request) async throws -> MessengerMessage? {
        guard let body = request.body.data else { return nil }
        let data = Data(buffer: body)
        guard let update = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return await parseUpdate(update)
    }

    // MARK: - 공용 Update 파싱

    /// Telegram Update 딕셔너리를 MessengerMessage로 변환한다.
    /// Polling과 Webhook 양쪽에서 공용.
    private func parseUpdate(_ update: [String: Any]) async -> MessengerMessage? {
        guard let msg = update["message"] as? [String: Any] else {
            return nil
        }

        guard let chat = msg["chat"] as? [String: Any],
              let chatId = chat["id"] as? Int64 else {
            return nil
        }

        let from = msg["from"] as? [String: Any]
        let senderId = (from?["id"] as? Int64).map(String.init) ?? "unknown"
        let firstName = from?["first_name"] as? String
        let lastName = from?["last_name"] as? String
        let senderName = [firstName, lastName].compactMap { $0 }.joined(separator: " ")

        // 허용 사용자 검사
        if !allowedUserIds.isEmpty && !allowedUserIds.contains(senderId) {
            print("[TelegramChannel:\(botId)] 미허용 사용자 거부: \(senderId) (\(senderName))")
            return nil
        }

        let text = msg["text"] as? String ?? ""

        // 이미지 처리
        var imageURLs: [String] = []
        if let photos = msg["photo"] as? [[String: Any]], let largest = photos.last {
            if let fileId = largest["file_id"] as? String {
                if let localPath = await downloadTelegramFile(fileId: fileId) {
                    imageURLs.append(localPath)
                }
            }
        }

        // 문서 처리
        if let document = msg["document"] as? [String: Any],
           let fileId = document["file_id"] as? String {
            if let localPath = await downloadTelegramFile(fileId: fileId) {
                imageURLs.append(localPath)
            }
        }

        if text.isEmpty && imageURLs.isEmpty { return nil }

        let messageText = text.isEmpty ? (msg["caption"] as? String ?? "") : text
        let messageId = (msg["message_id"] as? Int).map(String.init)

        let rawPayload = (try? JSONSerialization.data(withJSONObject: update)) ?? Data()

        return MessengerMessage(
            botId: botId,
            channelType: .telegram,
            chatId: String(chatId),
            senderId: senderId,
            senderName: senderName.isEmpty ? nil : senderName,
            text: messageText,
            imageURLs: imageURLs,
            replyToMessageId: messageId,
            rawPayload: rawPayload,
            receivedAt: Date()
        )
    }

    // MARK: - 응답 전송

    func sendReply(_ reply: MessengerReply) async throws {
        let url = URL(string: "\(apiBaseURL)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "chat_id": reply.chatId,
            "text": reply.text,
            "parse_mode": "Markdown"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            if httpResponse.statusCode == 400 {
                try await sendPlainText(chatId: reply.chatId, text: reply.text)
                return
            }
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            throw MessengerError.sendFailed(channel: .telegram, reason: "HTTP \(httpResponse.statusCode): \(errorBody)")
        }
    }

    private func sendPlainText(chatId: String, text: String) async throws {
        let url = URL(string: "\(apiBaseURL)/sendMessage")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "chat_id": chatId,
            "text": text
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
            throw MessengerError.sendFailed(channel: .telegram, reason: "Plain text 전송 실패: HTTP \(httpResponse.statusCode)")
        }
    }

    // MARK: - Typing Indicator

    func sendTypingIndicator(chatId: String) async throws {
        let url = URL(string: "\(apiBaseURL)/sendChatAction")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "chat_id": chatId,
            "action": "typing"
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: - 웹훅 등록 (옵션)

    /// Telegram Bot API에 웹훅 URL을 등록한다. Polling을 자동 중지.
    func registerWebhook(baseURL: String) async throws {
        // Webhook 등록 시 polling 중지 (Telegram은 webhook과 polling 상호 배타)
        stopPolling()

        let webhookURL = "\(baseURL)/telegram/\(botId)"
        let url = URL(string: "\(apiBaseURL)/setWebhook")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var body: [String: Any] = ["url": webhookURL]
        if !webhookSecret.isEmpty {
            body["secret_token"] = webhookSecret
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
            print("[TelegramChannel:\(botId)] 웹훅 등록 완료 (polling 중지): \(webhookURL)")
        } else {
            let errorBody = String(data: data, encoding: .utf8) ?? "unknown"
            print("[TelegramChannel:\(botId)] 웹훅 등록 실패: \(errorBody)")
            // 웹훅 등록 실패 시 polling 재시작
            startPolling()
        }
    }

    /// 웹훅 해제 후 polling 재시작.
    func unregisterWebhook() async throws {
        let url = URL(string: "\(apiBaseURL)/deleteWebhook")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        _ = try? await URLSession.shared.data(for: request)
        print("[TelegramChannel:\(botId)] 웹훅 해제, polling 재시작")
        startPolling()
    }

    // MARK: - 연결 테스트

    /// 봇 토큰 검증 + 허용 사용자에게 인사 메시지 전송.
    static func testConnection(botConfig: MessengerBotConfig) async -> (Bool, String) {
        guard let token = botConfig.credentials["botToken"], !token.isEmpty else {
            return (false, "Bot Token이 설정되지 않았습니다.")
        }

        let apiBase = "https://api.telegram.org/bot\(token)"

        guard let getMeURL = URL(string: "\(apiBase)/getMe") else {
            return (false, "잘못된 URL")
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: getMeURL)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ok = json["ok"] as? Bool, ok,
                  let result = json["result"] as? [String: Any] else {
                let body = String(data: data, encoding: .utf8) ?? "unknown"
                return (false, "토큰 인증 실패: \(body)")
            }

            let botUsername = result["username"] as? String ?? "unknown"
            let botFirstName = result["first_name"] as? String ?? ""

            if botConfig.allowedUserIds.isEmpty {
                return (true, "토큰 확인 완료: @\(botUsername) (\(botFirstName))\n허용 사용자가 없어 인사 메시지는 생략됨.")
            }

            let botName = botConfig.name.isEmpty ? botFirstName : botConfig.name
            let sessionInfo = botConfig.targetSessionName.map { "'\($0)' 세션에 연결되어 있어요." } ?? "아직 세션에 연결되지 않았어요."
            let greeting = "안녕하세요! 저는 \(botName) 봇이에요. \(sessionInfo) 메시지를 보내시면 AI가 답변해 드릴게요!"

            var sentCount = 0
            var failedUsers: [String] = []

            for userId in botConfig.allowedUserIds {
                let sendURL = URL(string: "\(apiBase)/sendMessage")!
                var request = URLRequest(url: sendURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")

                let body: [String: Any] = [
                    "chat_id": userId,
                    "text": greeting
                ]
                request.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (_, sendResponse) = try await URLSession.shared.data(for: request)
                if let httpResp = sendResponse as? HTTPURLResponse, httpResp.statusCode == 200 {
                    sentCount += 1
                } else {
                    failedUsers.append(userId)
                }
            }

            var resultMsg = "토큰 확인 완료: @\(botUsername)\n"
            resultMsg += "인사 메시지: \(sentCount)/\(botConfig.allowedUserIds.count)명 전송 완료"
            if !failedUsers.isEmpty {
                resultMsg += "\n전송 실패: \(failedUsers.joined(separator: ", ")) (봇에게 /start를 먼저 보내세요)"
            }
            return (true, resultMsg)
        } catch {
            return (false, "네트워크 오류: \(error.localizedDescription)")
        }
    }

    // MARK: - 파일 다운로드

    private func downloadTelegramFile(fileId: String) async -> String? {
        guard let getFileURL = URL(string: "\(apiBaseURL)/getFile?file_id=\(fileId)") else { return nil }

        guard let (data, _) = try? await URLSession.shared.data(from: getFileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let filePath = result["file_path"] as? String else {
            return nil
        }

        guard let downloadURL = URL(string: "https://api.telegram.org/file/bot\(botToken)/\(filePath)") else { return nil }
        guard let (fileData, _) = try? await URLSession.shared.data(from: downloadURL) else { return nil }

        let ext = (filePath as NSString).pathExtension.isEmpty ? "jpg" : (filePath as NSString).pathExtension
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("telegram_\(UUID().uuidString.prefix(8)).\(ext)")

        do {
            try fileData.write(to: tempURL)
            return tempURL.path
        } catch {
            print("[TelegramChannel:\(botId)] 파일 저장 실패: \(error)")
            return nil
        }
    }
}
