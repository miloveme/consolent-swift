import Foundation

/// CLI 도구 어댑터 프로토콜.
/// 각 CLI (Claude Code, Codex, Gemini 등)의 고유한 동작을 추상화한다.
protocol CLIAdapter {
    // MARK: - Identity

    /// 사람이 읽을 수 있는 이름 (예: "Claude Code")
    var name: String { get }

    /// API 모델 ID (예: "claude-code")
    var modelId: String { get }

    // MARK: - Binary

    /// 바이너리 검색 경로 목록 (우선순위 순)
    var defaultBinaryPaths: [String] { get }

    /// 바이너리 기본 이름 (PATH에서 검색용, 예: "claude")
    var defaultBinaryName: String { get }

    /// 바이너리 경로를 찾는다.
    /// 기본 구현은 하드코딩 경로 → login shell which → 이름 폴백.
    /// nvm 등 특수 경로가 필요한 어댑터는 오버라이드한다.
    func findBinaryPath() -> String

    /// 실행 명령을 구성한다.
    func buildCommand(binaryPath: String, args: [String], autoApprove: Bool) -> String

    // MARK: - Session Lifecycle

    /// 세션 종료 명령 (예: "/exit")
    var exitCommand: String { get }

    // MARK: - Completion Detection

    /// 응답 완료 신호 (예: "? for shortcuts")
    var readySignal: String { get }

    /// 처리 중 신호 (예: "esc to interrupt"). nil이면 처리 중 감지 불가.
    var processingSignal: String? { get }

    /// Screen buffer를 분석하여 CLI가 메시지 처리를 시작했는지 판단한다.
    /// 처리 중 고유 표시(스피너, "esc to interrupt" 등)가 나타나면 true.
    func hasProcessingStarted(screenBuffer: String) -> Bool

    /// Screen buffer를 분석하여 응답이 완료되었는지 판단한다.
    func isResponseComplete(screenBuffer: String) -> Bool

    // MARK: - Response Parsing

    /// Screen buffer 텍스트에서 응답 본문만 추출한다.
    /// TUI chrome, 프롬프트, 상태 표시 등을 제거하고 깨끗한 텍스트를 반환.
    func cleanResponse(_ screenText: String) -> String

    // MARK: - Output Parsing Patterns

    /// 승인 프롬프트 패턴 (regex). 이 패턴이 출력에서 감지되면 승인 요청으로 처리.
    var approvalPatterns: [String] { get }
}

// MARK: - Default Implementations

extension CLIAdapter {
    /// 바이너리 경로를 찾는다.
    /// 1) 하드코딩된 경로 확인
    /// 2) 사용자 login shell의 `which`로 검색
    /// 3) 바이너리 이름 폴백
    func findBinaryPath() -> String {
        let fm = FileManager.default

        // 1. 하드코딩된 경로에서 검색
        for path in defaultBinaryPaths {
            let expanded = NSString(string: path).expandingTildeInPath
            if fm.isExecutableFile(atPath: expanded) {
                return expanded
            }
        }

        // 2. 사용자 login shell에서 which로 검색
        //    독립 .app은 최소 PATH만 가지므로 login shell의 PATH를 활용
        if let resolved = resolveViaLoginShell(defaultBinaryName) {
            return resolved
        }

        return defaultBinaryName
    }

    /// 사용자 login shell의 환경에서 바이너리 경로를 찾는다.
    private func resolveViaLoginShell(_ binary: String) -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let process = Process()
        let pipe = Pipe()

        process.executableURL = URL(fileURLWithPath: shell)
        // -li: login + interactive. .zshrc의 PATH 설정(nvm 등)을 포함하여 탐색.
        process.arguments = ["-li", "-c", "which \(binary)"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if let path, !path.isEmpty, process.terminationStatus == 0 {
                return path
            }
        } catch {
            // 무시 — 다음 폴백 사용
        }

        return nil
    }

    /// 기본 승인 패턴 (대부분의 CLI에서 공통)
    var approvalPatterns: [String] {
        [
            "\\(y/n\\)\\s*$",
            "\\(Y/n\\)\\s*$",
            "\\[y/N\\]\\s*$",
            "\\[Y/n\\]\\s*$",
            "Do you want to proceed\\?",
            "Allow .+\\?\\s*\\(y\\)",
            "Press Enter to continue",
        ]
    }

    /// 기본 처리 시작 감지: processingSignal 출현 또는 readySignal 소멸
    func hasProcessingStarted(screenBuffer: String) -> Bool {
        if let processing = processingSignal {
            return screenBuffer.range(
                of: processing,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
        // processingSignal 없는 CLI: readySignal 소멸로 판단
        return !screenBuffer.contains(readySignal)
    }

    /// 기본 완료 감지: readySignal/processingSignal 기반
    func isResponseComplete(screenBuffer: String) -> Bool {
        let hasReady = screenBuffer.contains(readySignal)
        if let processing = processingSignal {
            let hasProcessing = screenBuffer.range(
                of: processing,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
            return hasReady || !hasProcessing
        }
        return hasReady
    }
}

// MARK: - CLI Type Enum

/// 지원하는 CLI 유형
enum CLIType: String, Codable, CaseIterable, Identifiable {
    case claudeCode = "claude-code"
    case codex = "codex"
    case gemini = "gemini"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        case .gemini: return "Gemini"
        }
    }

    /// 해당 CLI 유형의 어댑터를 생성한다.
    func createAdapter() -> CLIAdapter {
        switch self {
        case .claudeCode: return ClaudeCodeAdapter()
        case .codex: return CodexAdapter()
        case .gemini: return GeminiAdapter()
        }
    }
}
