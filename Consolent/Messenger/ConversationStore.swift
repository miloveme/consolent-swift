import Foundation
import SQLite3

/// 대화 히스토리를 SQLite로 영속화한다.
/// 메신저 봇 대화, 워크플로우 컨텍스트 전달 등에 사용.
///
/// DB 경로: ~/Library/Application Support/Consolent/conversations.sqlite
/// 테이블: messages (chat_key, role, content, metadata, created_at)
/// 대화 요청 경로.
enum ConversationSource: String, Sendable {
    case api        // POST /v1/chat/completions, /sessions/:id/message
    case mcp        // MCP session_send_message
    case messenger  // 메신저 봇 (Telegram 등)
}

final class ConversationStore: @unchecked Sendable {

    static let shared = ConversationStore()

    // MARK: - 모델

    /// 기존 호환용 턴 모델.
    struct Turn: Sendable {
        let userText: String
        let assistantText: String
        let timestamp: Date
    }

    /// 범용 메시지 모델 (워크플로우/LLM API 대비).
    struct Message: Sendable {
        let id: Int64
        let chatKey: String
        let role: String        // "user", "assistant", "system", "context"
        let content: String
        let metadata: String?   // JSON (세션명, 봇ID, 토큰수 등)
        let createdAt: Date
    }

    // MARK: - 프로퍼티

    private var db: OpaquePointer?
    private let lock = NSLock()

    // MARK: - 초기화

    init() {
        openDatabase()
        createTableIfNeeded()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private static var dbURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Consolent", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.sqlite")
    }

    private func openDatabase() {
        let path = Self.dbURL.path
        if sqlite3_open(path, &db) != SQLITE_OK {
            print("[ConversationStore] DB 열기 실패: \(path)")
            db = nil
        }
        // WAL 모드 (동시 읽기 성능 향상)
        execute("PRAGMA journal_mode=WAL")
    }

    private func createTableIfNeeded() {
        execute("""
            CREATE TABLE IF NOT EXISTS messages (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                chat_key TEXT NOT NULL,
                role TEXT NOT NULL,
                content TEXT NOT NULL,
                metadata TEXT,
                created_at REAL NOT NULL
            )
        """)
        execute("CREATE INDEX IF NOT EXISTS idx_messages_chatkey_time ON messages (chat_key, created_at)")
    }

    // MARK: - 기존 인터페이스 (호환)

    /// 대화 턴 추가 (user + assistant 한 쌍).
    func addTurn(chatKey: String, userText: String, assistantText: String, maxTurns: Int = 10, source: ConversationSource? = nil) {
        lock.lock()
        defer { lock.unlock() }

        let meta = source.map { "{\"source\":\"\($0.rawValue)\"}" }
        let now = Date().timeIntervalSince1970
        print("[ConversationStore] addTurn: key=\(chatKey), source=\(source?.rawValue ?? "nil"), user=\(userText.prefix(50))..., assistant=\(assistantText.prefix(50))...")
        insertMessage(chatKey: chatKey, role: "user", content: userText, metadata: meta, createdAt: now)
        insertMessage(chatKey: chatKey, role: "assistant", content: assistantText, metadata: meta, createdAt: now + 0.001)

        // maxTurns 초과 시 오래된 메시지 정리 (턴 1개 = 메시지 2개)
        if maxTurns > 0 {
            trimMessages(chatKey: chatKey, keepCount: maxTurns * 2)
        }
    }

    /// 최근 대화 히스토리를 Turn 형태로 반환한다.
    func getHistory(chatKey: String, maxTurns: Int = 10) -> [Turn] {
        lock.lock()
        defer { lock.unlock() }

        let messages = fetchMessages(chatKey: chatKey, limit: maxTurns * 2)

        // user+assistant 쌍으로 묶기
        var turns: [Turn] = []
        var i = 0
        while i < messages.count - 1 {
            if messages[i].role == "user" && messages[i + 1].role == "assistant" {
                turns.append(Turn(
                    userText: messages[i].content,
                    assistantText: messages[i + 1].content,
                    timestamp: messages[i].createdAt
                ))
                i += 2
            } else {
                i += 1
            }
        }
        return turns
    }

    /// 특정 채팅의 히스토리를 삭제한다.
    func clearHistory(chatKey: String) {
        lock.lock()
        defer { lock.unlock() }
        execute("DELETE FROM messages WHERE chat_key = '\(escapeSql(chatKey))'")
    }

    /// 만료된 대화를 정리한다 (TTL 기반).
    func pruneExpired(olderThan ttl: TimeInterval = 3600) {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-ttl).timeIntervalSince1970
        execute("DELETE FROM messages WHERE created_at < \(cutoff)")
    }

    /// 전체 대화(고유 chat_key) 수.
    var conversationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queryInt("SELECT COUNT(DISTINCT chat_key) FROM messages")
    }

    /// 전체 메시지 수.
    var totalMessageCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return queryInt("SELECT COUNT(*) FROM messages")
    }

    /// DB 파일 크기 (바이트).
    var databaseSize: Int64 {
        let path = Self.dbURL.path
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? Int64 else { return 0 }
        return size
    }

    /// 전체 chat_key 목록과 각 대화의 메시지 수, 최종 시각을 반환한다.
    func allConversations() -> [(chatKey: String, messageCount: Int, lastActivity: Date)] {
        lock.lock()
        defer { lock.unlock() }

        let sql = "SELECT chat_key, COUNT(*) as cnt, MAX(created_at) as last_at FROM messages GROUP BY chat_key ORDER BY last_at DESC"
        guard let db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var results: [(String, Int, Date)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let chatKey = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            let lastAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            results.append((chatKey, count, lastAt))
        }
        return results
    }

    // MARK: - 확장 인터페이스 (워크플로우/LLM API 대비)

    /// 단일 메시지 추가.
    func addMessage(chatKey: String, role: String, content: String, metadata: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        insertMessage(chatKey: chatKey, role: role, content: content, metadata: metadata, createdAt: Date().timeIntervalSince1970)
    }

    /// 특정 채팅의 최근 메시지를 반환한다.
    func getMessages(chatKey: String, limit: Int = 20) -> [Message] {
        lock.lock()
        defer { lock.unlock() }
        return fetchMessages(chatKey: chatKey, limit: limit)
    }

    /// 특정 채팅에서 키워드 검색.
    func searchMessages(chatKey: String, query: String) -> [Message] {
        lock.lock()
        defer { lock.unlock() }

        let escaped = escapeSql(query)
        let sql = "SELECT id, chat_key, role, content, metadata, created_at FROM messages WHERE chat_key = '\(escapeSql(chatKey))' AND content LIKE '%\(escaped)%' ORDER BY created_at ASC LIMIT 100"
        return queryMessages(sql)
    }

    /// 전체 대화에서 키워드 검색.
    func searchAllMessages(query: String) -> [Message] {
        lock.lock()
        defer { lock.unlock() }

        let escaped = escapeSql(query)
        let sql = "SELECT id, chat_key, role, content, metadata, created_at FROM messages WHERE content LIKE '%\(escaped)%' ORDER BY created_at DESC LIMIT 100"
        return queryMessages(sql)
    }

    /// 필터 기반 검색.
    func searchWithFilter(
        chatKey: String? = nil,
        keyword: String? = nil,
        source: String? = nil,
        role: String? = nil,
        dateFrom: Date? = nil,
        dateTo: Date? = nil,
        limit: Int = 200
    ) -> [Message] {
        lock.lock()
        defer { lock.unlock() }

        var conditions: [String] = []

        if let chatKey {
            conditions.append("chat_key = '\(escapeSql(chatKey))'")
        }
        if let keyword, !keyword.isEmpty {
            conditions.append("content LIKE '%\(escapeSql(keyword))%'")
        }
        if let source, !source.isEmpty {
            conditions.append("metadata LIKE '%\"\(escapeSql(source))\"%'")
        }
        if let role, !role.isEmpty {
            conditions.append("role = '\(escapeSql(role))'")
        }
        if let dateFrom {
            conditions.append("created_at >= \(dateFrom.timeIntervalSince1970)")
        }
        if let dateTo {
            conditions.append("created_at <= \(dateTo.timeIntervalSince1970)")
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE \(conditions.joined(separator: " AND "))"
        let sql = "SELECT id, chat_key, role, content, metadata, created_at FROM messages \(whereClause) ORDER BY created_at DESC LIMIT \(limit)"
        return queryMessages(sql)
    }

    /// 특정 채팅의 메시지 수.
    func messageCount(chatKey: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return queryInt("SELECT COUNT(*) FROM messages WHERE chat_key = '\(escapeSql(chatKey))'")
    }

    // MARK: - 내부 SQL 헬퍼

    private func insertMessage(chatKey: String, role: String, content: String, metadata: String?, createdAt: Double) {
        guard let db else { return }

        let sql = "INSERT INTO messages (chat_key, role, content, metadata, created_at) VALUES (?, ?, ?, ?, ?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (chatKey as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (role as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (content as NSString).utf8String, -1, nil)
        if let metadata {
            sqlite3_bind_text(stmt, 4, (metadata as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        sqlite3_bind_double(stmt, 5, createdAt)

        sqlite3_step(stmt)
    }

    private func trimMessages(chatKey: String, keepCount: Int) {
        guard let db else { return }

        // 최신 keepCount개를 제외하고 삭제
        let sql = """
            DELETE FROM messages WHERE chat_key = ? AND id NOT IN (
                SELECT id FROM messages WHERE chat_key = ? ORDER BY created_at DESC LIMIT ?
            )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (chatKey as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (chatKey as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 3, Int32(keepCount))

        sqlite3_step(stmt)
    }

    private func fetchMessages(chatKey: String, limit: Int) -> [Message] {
        // 서브쿼리로 최신 N개를 가져온 후 시간순 정렬
        let sql = """
            SELECT id, chat_key, role, content, metadata, created_at FROM (
                SELECT * FROM messages WHERE chat_key = '\(escapeSql(chatKey))'
                ORDER BY created_at DESC LIMIT \(limit)
            ) ORDER BY created_at ASC
        """
        return queryMessages(sql)
    }

    private func queryMessages(_ sql: String) -> [Message] {
        guard let db else { return [] }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var messages: [Message] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = sqlite3_column_int64(stmt, 0)
            let chatKey = String(cString: sqlite3_column_text(stmt, 1))
            let role = String(cString: sqlite3_column_text(stmt, 2))
            let content = String(cString: sqlite3_column_text(stmt, 3))
            let metadata: String? = sqlite3_column_type(stmt, 4) != SQLITE_NULL
                ? String(cString: sqlite3_column_text(stmt, 4)) : nil
            let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))

            messages.append(Message(
                id: id, chatKey: chatKey, role: role, content: content,
                metadata: metadata, createdAt: createdAt
            ))
        }
        return messages
    }

    private func queryInt(_ sql: String) -> Int {
        guard let db else { return 0 }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }

        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    @discardableResult
    private func execute(_ sql: String) -> Bool {
        guard let db else { return false }
        return sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func escapeSql(_ text: String) -> String {
        text.replacingOccurrences(of: "'", with: "''")
    }
}
