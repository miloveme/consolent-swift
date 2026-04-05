import Foundation

/// 메신저 메시지를 세션으로 라우팅하고 응답을 전달하는 디스패처.
/// chatId별 직렬 큐로 동시성을 관리한다.
actor MessageDispatcher {

    private let sessionManager = SessionManager.shared
    private let conversationStore = ConversationStore.shared

    /// 현재 처리 중인 chatKey 집합 (직렬화용)
    private var activeChatTasks: Set<String> = []

    /// chatKey별 대기 중인 continuation 큐
    private var waitingQueues: [String: [CheckedContinuation<Void, Never>]] = [:]

    // MARK: - 메시지 디스패치

    /// 메신저 메시지를 수신하여 세션으로 라우팅하고 응답을 전달한다.
    func dispatch(
        message: MessengerMessage,
        channel: any MessengerChannel,
        botConfig: MessengerBotConfig
    ) async {
        let chatKey = "\(message.botId):\(message.chatId)"

        // 1. chatId별 직렬 대기
        await waitForTurn(chatKey: chatKey)
        defer { releaseTurn(chatKey: chatKey) }

        print("[MessageDispatcher] 메시지 수신: bot=\(botConfig.name) chat=\(message.chatId) — \"\(message.text.prefix(50))\"")

        // 2. 봇에 연결된 세션 조회
        guard let sessionName = botConfig.targetSessionName else {
            print("[MessageDispatcher] 봇 '\(botConfig.name)'에 연결된 세션 없음")
            try? await channel.sendReply(MessengerReply(
                chatId: message.chatId,
                text: "[Consolent] 이 봇에 연결된 세션이 없습니다. 설정에서 세션을 연결해주세요."
            ))
            return
        }

        guard let session = sessionManager.getSession(name: sessionName) else {
            print("[MessageDispatcher] 세션 '\(sessionName)' 없음")
            try? await channel.sendReply(MessengerReply(
                chatId: message.chatId,
                text: "[Consolent] 세션 '\(sessionName)'을 찾을 수 없습니다."
            ))
            return
        }

        // 3. 세션 상태 확인 — busy면 대기
        let maxWait: TimeInterval = 60
        let waitStart = Date()
        while session.status == .busy {
            if Date().timeIntervalSince(waitStart) > maxWait {
                try? await channel.sendReply(MessengerReply(
                    chatId: message.chatId,
                    text: "[Consolent] 세션이 사용 중입니다. 잠시 후 다시 시도해주세요."
                ))
                return
            }
            // 대기 중 typing indicator 갱신
            try? await channel.sendTypingIndicator(chatId: message.chatId)
            try? await Task.sleep(nanoseconds: 3_000_000_000) // 3초
        }

        guard session.status == .ready else {
            try? await channel.sendReply(MessengerReply(
                chatId: message.chatId,
                text: "[Consolent] 세션이 준비되지 않았습니다 (상태: \(session.status.rawValue))."
            ))
            return
        }

        // 4. typing indicator 전송
        try? await channel.sendTypingIndicator(chatId: message.chatId)

        // 5. 세션에 메시지 직접 전송
        do {
            let timeout = TimeInterval(botConfig.responseTimeout)

            // 긴 응답 대기 중 typing indicator 주기적 갱신 (Telegram은 5초 후 만료)
            let typingTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000) // 4초
                    guard !Task.isCancelled else { break }
                    try? await channel.sendTypingIndicator(chatId: message.chatId)
                }
            }

            let response = try await session.sendMessage(
                text: message.text,
                systemPrompt: botConfig.systemPrompt,
                imagePaths: message.imageURLs.isEmpty ? nil : message.imageURLs,
                timeout: timeout
            )

            typingTask.cancel()

            let resultText = response.response.result

            // 6. 대화 히스토리 저장
            conversationStore.addTurn(
                chatKey: chatKey,
                userText: message.text,
                assistantText: resultText,
                maxTurns: botConfig.maxHistoryTurns,
                source: .messenger
            )

            // 7. 응답 분할 후 전송
            let chunks = splitMessage(resultText, maxLength: channel.maxMessageLength)
            for chunk in chunks {
                try? await channel.sendReply(MessengerReply(
                    chatId: message.chatId,
                    text: chunk
                ))
            }

            print("[MessageDispatcher] 응답 전송 완료: bot=\(botConfig.name) chat=\(message.chatId) (\(resultText.count)자, \(chunks.count)청크)")
        } catch {
            print("[MessageDispatcher] 세션 에러: \(error.localizedDescription)")
            try? await channel.sendReply(MessengerReply(
                chatId: message.chatId,
                text: "[Error] \(error.localizedDescription)"
            ))
        }
    }

    // MARK: - 직렬 큐 (chatId별)

    private func waitForTurn(chatKey: String) async {
        if activeChatTasks.contains(chatKey) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waitingQueues[chatKey, default: []].append(continuation)
            }
        }
        activeChatTasks.insert(chatKey)
    }

    private func releaseTurn(chatKey: String) {
        activeChatTasks.remove(chatKey)
        if var queue = waitingQueues[chatKey], !queue.isEmpty {
            let next = queue.removeFirst()
            waitingQueues[chatKey] = queue.isEmpty ? nil : queue
            next.resume()
        }
    }

    // MARK: - 대화 히스토리

    func getHistory(chatKey: String, maxTurns: Int = 10) -> [ConversationStore.Turn] {
        conversationStore.getHistory(chatKey: chatKey, maxTurns: maxTurns)
    }

    func clearHistory(chatKey: String) {
        conversationStore.clearHistory(chatKey: chatKey)
    }

    func pruneExpiredConversations(olderThan ttl: TimeInterval = 3600) {
        conversationStore.pruneExpired(olderThan: ttl)
    }
}

// MARK: - 메시지 분할

/// 텍스트를 maxLength 이하로 분할한다.
/// 단락(빈 줄) → 문장(마침표) → 단어(공백) → 강제 분할 순으로 시도.
func splitMessage(_ text: String, maxLength: Int) -> [String] {
    guard text.count > maxLength else { return [text] }

    var chunks: [String] = []
    var remaining = text

    while !remaining.isEmpty {
        if remaining.count <= maxLength {
            chunks.append(remaining)
            break
        }

        let candidate = String(remaining.prefix(maxLength))
        var splitIndex = maxLength

        if let range = candidate.range(of: "\n\n", options: .backwards) {
            splitIndex = candidate.distance(from: candidate.startIndex, to: range.upperBound)
        } else if let range = candidate.range(of: "\n", options: .backwards) {
            splitIndex = candidate.distance(from: candidate.startIndex, to: range.upperBound)
        } else if let range = candidate.range(of: ". ", options: .backwards) {
            splitIndex = candidate.distance(from: candidate.startIndex, to: range.upperBound)
        } else if let range = candidate.range(of: " ", options: .backwards) {
            splitIndex = candidate.distance(from: candidate.startIndex, to: range.upperBound)
        }

        let chunk = String(remaining.prefix(splitIndex)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !chunk.isEmpty {
            chunks.append(chunk)
        }
        remaining = String(remaining.dropFirst(splitIndex))
    }

    return chunks.isEmpty ? [text] : chunks
}
