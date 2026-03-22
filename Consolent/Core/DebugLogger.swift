import Foundation

/// 디버그 로깅 시스템.
/// PTY 원본 출력, 파싱 과정, API 요청/응답을 JSON-Lines 형식으로 기록한다.
/// 기록된 데이터는 나중에 파싱 엔진 테스트에 사용할 수 있다.
///
/// 로그 위치: `~/Library/Logs/Consolent/debug/{날짜}/{세션파일}.jsonl`
final class DebugLogger {

    static let shared = DebugLogger()

    /// 로깅 활성 여부 (AppConfig.debugLoggingEnabled와 연동)
    var isEnabled: Bool { AppConfig.shared.debugLoggingEnabled }

    /// 로그 보관 기간 (일)
    var retentionDays: Int { AppConfig.shared.debugLogRetentionDays }

    /// 로그 루트 디렉토리
    static let logDirectory: URL = {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Consolent/debug")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs
    }()

    /// 세션별 파일 핸들
    private var sessionHandles: [String: FileHandle] = [:]

    /// 파일 I/O 전용 직렬 큐
    private let queue = DispatchQueue(label: "com.consolent.debuglogger", qos: .utility)

    /// 날짜 포맷터 (디렉토리명)
    private let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// ISO 8601 타임스탬프
    private let isoFmt: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - 세션 라이프사이클

    /// 세션 시작 시 로그 파일 생성
    func startSession(sessionId: String, cliType: String, name: String) {
        guard isEnabled else { return }
        queue.async { [self] in
            let dateDir = Self.logDirectory.appendingPathComponent(dateFmt.string(from: Date()))
            try? FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

            let timeFmt = DateFormatter()
            timeFmt.dateFormat = "HH-mm-ss"
            let filename = "\(sessionId)_\(cliType)_\(timeFmt.string(from: Date())).jsonl"
            let filePath = dateDir.appendingPathComponent(filename)

            FileManager.default.createFile(atPath: filePath.path, contents: nil)
            if let handle = FileHandle(forWritingAtPath: filePath.path) {
                sessionHandles[sessionId] = handle
            }

            writeEntry(sessionId: sessionId, event: "session_start", data: [
                "cliType": cliType,
                "name": name,
            ])
        }
    }

    /// 세션 종료 시 파일 핸들 닫기
    func endSession(sessionId: String) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "session_end", data: [:])
        queue.async { [self] in
            sessionHandles[sessionId]?.closeFile()
            sessionHandles.removeValue(forKey: sessionId)
        }
    }

    // MARK: - 로깅 메서드

    /// PTY 원본 출력 (handleOutput에서 호출)
    func logPTYOutput(sessionId: String, rawData: Data, strippedText: String?) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "pty_output", data: [
            "rawBase64": rawData.base64EncodedString(),
            "rawLength": rawData.count,
            "strippedText": strippedText ?? "",
        ])
    }

    /// 메시지 전송 (sendMessage/sendMessageStreaming에서 호출)
    func logMessageSent(sessionId: String, messageId: String, text: String, streaming: Bool) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "message_sent", data: [
            "messageId": messageId,
            "text": text,
            "streaming": streaming,
        ])
    }

    /// 스크린 버퍼 스냅샷 (응답 수집 시 호출)
    func logScreenBuffer(sessionId: String, screenText: String, context: String) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "screen_buffer", data: [
            "screenText": screenText,
            "context": context,
            "lineCount": screenText.components(separatedBy: "\n").count,
        ])
    }

    /// 파싱 결과 (adapter.cleanResponse 전후)
    func logParsingResult(sessionId: String, screenText: String, cleanText: String,
                          adapterType: String, context: String) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "parsing_result", data: [
            "screenText": screenText,
            "cleanText": cleanText,
            "adapterType": adapterType,
            "context": context,
            "screenLength": screenText.count,
            "cleanLength": cleanText.count,
        ])
    }

    /// 스트리밍 폴링 (pollStreamingDelta에서 호출, 변화가 있을 때만)
    func logStreamingPoll(sessionId: String, cleanText: String, delta: String,
                          sentLength: Int, totalLength: Int, elapsed: TimeInterval) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "streaming_poll", data: [
            "delta": delta,
            "deltaLength": delta.count,
            "sentLength": sentLength,
            "totalLength": totalLength,
            "elapsed": String(format: "%.1f", elapsed),
        ])
    }

    /// 스트리밍 baseline 캡처
    func logStreamingBaseline(sessionId: String, baseline: String) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "streaming_baseline", data: [
            "baseline": baseline,
            "length": baseline.count,
        ])
    }

    /// 완료 감지 (completeResponse/completeStreamingResponse에서 호출)
    func logCompletionDetected(sessionId: String, signal: String, screenText: String,
                               cleanText: String, context: String) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "completion_detected", data: [
            "signal": signal,
            "screenText": screenText,
            "cleanText": cleanText,
            "context": context,
        ])
    }

    /// API 요청 수신
    func logAPIRequest(sessionId: String?, method: String, path: String,
                       model: String?, message: String, streaming: Bool) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId ?? "api", event: "api_request", data: [
            "method": method,
            "path": path,
            "model": model ?? "",
            "message": message,
            "streaming": streaming,
        ])
    }

    /// API 응답 발송
    func logAPIResponse(sessionId: String?, path: String, statusCode: Int,
                        responseText: String, durationMs: Int) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId ?? "api", event: "api_response", data: [
            "path": path,
            "statusCode": statusCode,
            "responseText": responseText,
            "responseLength": responseText.count,
            "durationMs": durationMs,
        ])
    }

    /// 에러 기록
    func logError(sessionId: String, message: String, context: String) {
        guard isEnabled else { return }
        writeEntry(sessionId: sessionId, event: "error", data: [
            "message": message,
            "context": context,
        ])
    }

    // MARK: - 로그 정리

    /// 보관 기간이 지난 로그 삭제
    func cleanupOldLogs() {
        queue.async { [self] in
            let fm = FileManager.default
            guard let contents = try? fm.contentsOfDirectory(
                at: Self.logDirectory, includingPropertiesForKeys: nil
            ) else { return }

            let cutoff = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date())!
            let cutoffStr = dateFmt.string(from: cutoff)

            for dir in contents where dir.hasDirectoryPath {
                if dir.lastPathComponent < cutoffStr {
                    try? fm.removeItem(at: dir)
                    print("[DebugLogger] 오래된 로그 삭제: \(dir.lastPathComponent)")
                }
            }
        }
    }

    /// 로그 디렉토리 크기 (바이트)
    func logDirectorySize() -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: Self.logDirectory,
                                              includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Private

    /// JSON-Lines 형식으로 1행 쓰기
    private func writeEntry(sessionId: String, event: String, data: [String: Any]) {
        queue.async { [self] in
            var entry: [String: Any] = [
                "timestamp": isoFmt.string(from: Date()),
                "sessionId": sessionId,
                "event": event,
                "data": data,
            ]

            // sessionId에 해당하는 파일 핸들 찾기
            let handle = sessionHandles[sessionId]

            // 핸들이 없으면 (API 로그 등) 공용 로그 파일에 기록
            let targetHandle: FileHandle?
            if let h = handle {
                targetHandle = h
            } else {
                targetHandle = getOrCreateSharedHandle()
            }

            guard let fh = targetHandle else { return }

            do {
                let jsonData = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
                fh.write(jsonData)
                fh.write("\n".data(using: .utf8)!)
            } catch {
                // JSON 변환 실패 시 무시 (로깅이 앱을 중단시키면 안 됨)
            }
        }
    }

    /// 세션에 속하지 않는 로그용 공용 파일 핸들
    private var sharedHandle: FileHandle?

    private func getOrCreateSharedHandle() -> FileHandle? {
        if let h = sharedHandle { return h }

        let dateDir = Self.logDirectory.appendingPathComponent(dateFmt.string(from: Date()))
        try? FileManager.default.createDirectory(at: dateDir, withIntermediateDirectories: true)

        let filename = "api_\(dateFmt.string(from: Date())).jsonl"
        let filePath = dateDir.appendingPathComponent(filename)
        FileManager.default.createFile(atPath: filePath.path, contents: nil)
        sharedHandle = FileHandle(forWritingAtPath: filePath.path)
        return sharedHandle
    }
}
