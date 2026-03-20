import XCTest
@testable import Consolent

final class CodexAdapterTests: XCTestCase {

    let adapter = CodexAdapter()

    // MARK: - Identity

    func testAdapterIdentity() {
        XCTAssertEqual(adapter.name, "Codex")
        XCTAssertEqual(adapter.modelId, "codex")
        XCTAssertEqual(adapter.exitCommand, "/exit")
        XCTAssertEqual(adapter.defaultBinaryName, "codex")
    }

    // MARK: - Build Command

    func testBuildCommand_basic() {
        let cmd = adapter.buildCommand(binaryPath: "/usr/local/bin/codex", args: [], autoApprove: false)
        XCTAssertEqual(cmd, "/usr/local/bin/codex")
    }

    func testBuildCommand_withAutoApprove() {
        let cmd = adapter.buildCommand(binaryPath: "/usr/local/bin/codex", args: [], autoApprove: true)
        XCTAssertEqual(cmd, "/usr/local/bin/codex --full-auto")
    }

    func testBuildCommand_withArgs() {
        let cmd = adapter.buildCommand(binaryPath: "/usr/local/bin/codex", args: ["-m", "o3"], autoApprove: false)
        XCTAssertEqual(cmd, "/usr/local/bin/codex -m o3")
    }

    func testBuildCommand_withAutoApproveAndArgs() {
        let cmd = adapter.buildCommand(binaryPath: "/usr/local/bin/codex", args: ["-m", "o3"], autoApprove: true)
        XCTAssertEqual(cmd, "/usr/local/bin/codex --full-auto -m o3")
    }

    // MARK: - Signals

    func testReadySignal() {
        XCTAssertEqual(adapter.readySignal, "% left")
    }

    func testProcessingSignal() {
        XCTAssertEqual(adapter.processingSignal, "esc\\s+to\\s+interrupt")
    }

    // MARK: - Completion Detection

    func testHasProcessingStarted_withProcessingSignal() {
        let screen = "• Working (3s • esc to interrupt)"
        XCTAssertTrue(adapter.hasProcessingStarted(screenBuffer: screen))
    }

    func testHasProcessingStarted_noSignal() {
        let screen = "gpt-5.3-codex medium · 96% left · ~/projects"
        XCTAssertFalse(adapter.hasProcessingStarted(screenBuffer: screen))
    }

    func testIsResponseComplete_withReadySignal() {
        let screen = "• 응답 완료\ngpt-5.3-codex medium · 96% left · ~/projects"
        XCTAssertTrue(adapter.isResponseComplete(screenBuffer: screen))
    }

    func testIsResponseComplete_processingInProgress() {
        let screen = "• Working (5s • esc to interrupt)"
        XCTAssertFalse(adapter.isResponseComplete(screenBuffer: screen))
    }

    func testIsResponseComplete_readyAndProcessingBoth() {
        // ready 신호와 processing 신호가 동시에 있으면 → ready 우선 (완료)
        let screen = "96% left\nesc to interrupt"
        XCTAssertTrue(adapter.isResponseComplete(screenBuffer: screen))
    }

    // MARK: - cleanResponse: 기본 동작

    func testCleanResponse_emptyScreen() {
        XCTAssertEqual(adapter.cleanResponse(""), "")
    }

    func testCleanResponse_noAssistantResponse() {
        let screen = """
        › hello
        some echo text
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "")
    }

    func testCleanResponse_extractsBasicResponse() {
        let screen = """
        › hello
        • 안녕하세요, 무엇을 도와드릴까요?
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요, 무엇을 도와드릴까요?")
    }

    // MARK: - cleanResponse: 사용자 입력 필터

    func testCleanResponse_skipsUserInput() {
        let screen = """
        › fibonacci 함수 만들어줘
        • 네, fibonacci 함수를 작성합니다.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "네, fibonacci 함수를 작성합니다.")
    }

    func testCleanResponse_lastTurnOnly() {
        let screen = """
        › first question
        • first answer
        › second question
        • second answer
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "second answer")
    }

    // MARK: - cleanResponse: 멀티라인 응답

    func testCleanResponse_preservesMultilineResponse() {
        let screen = """
        › explain
        • 첫 번째 단락입니다.

        두 번째 단락입니다.

        세 번째 단락입니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("첫 번째 단락입니다."))
        XCTAssertTrue(result.contains("두 번째 단락입니다."))
        XCTAssertTrue(result.contains("세 번째 단락입니다."))
    }

    // MARK: - cleanResponse: 도구 실행 필터

    func testCleanResponse_filtersToolRunLine() {
        let screen = """
        › list files
        • Ran `ls -la`
        • 파일 목록을 확인했습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("파일 목록을 확인했습니다."))
        XCTAssertFalse(result.contains("Ran"))
    }

    func testCleanResponse_filtersToolRunningLine() {
        let screen = """
        › do something
        • Running `npm install`
        • 설치가 완료되었습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("설치가 완료되었습니다."))
        XCTAssertFalse(result.contains("Running"))
    }

    func testCleanResponse_filtersExploredLine() {
        let screen = """
        › check files
        • Explored directory structure
        • 디렉토리 구조를 확인했습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("Explored"))
        XCTAssertTrue(result.contains("디렉토리 구조를 확인했습니다."))
    }

    func testCleanResponse_filtersToolOutputPrefix() {
        let screen = """
        › run test
        • Ran `swift test`
          └ All tests passed
        • 테스트가 통과했습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("└"))
        XCTAssertTrue(result.contains("테스트가 통과했습니다."))
    }

    func testCleanResponse_filtersToolStatusMarkers() {
        let screen = """
        › do it
        • Ran `echo hello` ✓
        • 완료되었습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("✓"))
        XCTAssertTrue(result.contains("완료되었습니다."))
    }

    // MARK: - cleanResponse: 상태 표시 필터

    func testCleanResponse_filtersWorkingStatus() {
        let screen = """
        › do something
        • Working (3s • esc to interrupt)
        • 작업이 완료되었습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("Working"))
        XCTAssertTrue(result.contains("작업이 완료되었습니다."))
    }

    func testCleanResponse_filtersAnalyzingStatus() {
        let screen = """
        › analyze
        • Analyzing code structure
        • 코드 분석 결과입니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("Analyzing"))
        XCTAssertTrue(result.contains("코드 분석 결과입니다."))
    }

    // MARK: - cleanResponse: TUI chrome 필터

    func testCleanResponse_filtersStatusBarLine() {
        let screen = """
        › hello
        • 응답입니다
        gpt-5.3-codex medium · 96% left · ~/projects
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답입니다")
    }

    func testCleanResponse_filtersEscToInterrupt() {
        let screen = """
        › hello
        • 긴 응답입니다
        esc to interrupt
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "긴 응답입니다")
    }

    func testCleanResponse_filtersContextLeft() {
        let screen = """
        › hello
        • 응답
        100% context left
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersTipLine() {
        let screen = """
        Tip: Use /fast to enable faster inference
        › hello
        • 응답입니다
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답입니다")
    }

    func testCleanResponse_filtersWelcomeLine() {
        let screen = """
        Welcome to Codex, OpenAI's coding agent
        › hello
        • 응답
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersInterruptMessage() {
        let screen = """
        › hello
        • 응답
        Conversation interrupted - tell the model what to do differently.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    // MARK: - cleanResponse: 승인 UI 필터

    func testCleanResponse_filtersApprovalPrompt() {
        let screen = """
        › do something risky
        Would you like to run the following command?
        › 1. Yes, proceed (y)
          2. Yes, and don't ask again
          3. No, and tell Codex what to do differently (esc)
        Press enter to confirm or esc to cancel
        • 명령을 실행했습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("Would you like"))
        XCTAssertFalse(result.contains("proceed"))
        XCTAssertTrue(result.contains("명령을 실행했습니다."))
    }

    func testCleanResponse_filtersApprovalHistory() {
        let screen = """
        › do it
        ✔ You approved codex to run `ls` this time
        • 결과입니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("approved"))
        XCTAssertTrue(result.contains("결과입니다."))
    }

    // MARK: - cleanResponse: 기타 필터

    func testCleanResponse_filtersBoxBorders() {
        let screen = """
        ╭─────────────────────╮
        │  Codex              │
        ╰─────────────────────╯
        › hi
        • 응답
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersSeparatorLines() {
        let screen = """
        › hello
        • 첫 번째 줄
        ───────────────────
        두 번째 줄
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("첫 번째 줄"))
        XCTAssertTrue(result.contains("두 번째 줄"))
        XCTAssertFalse(result.contains("───"))
    }

    func testCleanResponse_filtersErrorWarning() {
        let screen = """
        › hello
        ■ Error: something went wrong
        ⚠ Warning: low memory
        • 응답입니다
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertFalse(result.contains("Error"))
        XCTAssertFalse(result.contains("Warning"))
        XCTAssertTrue(result.contains("응답입니다"))
    }

    // MARK: - cleanResponse: null 문자 제거

    func testCleanResponse_nullCharacterRemoval() {
        let screen = "› hello\n• 안\u{0000}녕\u{0000}하\u{0000}세\u{0000}요"
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요")
    }

    // MARK: - cleanResponse: CJK 패딩 보정

    func testCleanResponse_cjkPaddingInResponse() {
        let screen = """
        › 안 녕
        • 안 녕 하 세 요 , 무 엇 을  도 와 드 릴 까 요 ?
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertEqual(result, "안녕하세요, 무엇을 도와드릴까요?")
    }

    // MARK: - cleanResponse: 입력 플레이스홀더 처리

    func testCleanResponse_preservesResponseBeforeInputPlaceholder() {
        // Codex는 응답 후 입력 플레이스홀더(› Find and fix...)를 표시한다.
        // 이 플레이스홀더가 수집된 응답을 클리어해서는 안 됨.
        let screen = """
        ╭────────────────────────────────────────────────────╮
        │ >_ OpenAI Codex (v0.114.0)                         │
        │                                                    │
        │ model:     gpt-5.3-codex medium   /model to change │
        │ directory: ~/Documents/Dev/AI/codex_projects       │
        ╰────────────────────────────────────────────────────╯

          Tip: New Try the Codex App with 2x rate limits until April 2nd.

        › Say just the word OK and nothing else.

        • OK

        › Find and fix a bug in @filename

          gpt-5.3-codex medium · 96% left · ~/Documents/Dev/AI/codex_projects
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "OK")
    }

    func testCleanResponse_lastTurnResponseBeforePlaceholder() {
        // 멀티턴 + 입력 플레이스홀더: 마지막 턴의 응답만 유지
        let screen = """
        › first question
        • first answer
        › second question
        • second answer is here
        › Describe a bug or paste a URL to a GitHub Issue
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "second answer is here")
    }

    func testCleanResponse_newTurnOverridesBackup() {
        // 새 턴에서 실제 응답이 있으면 이전 백업이 아닌 새 응답을 사용
        let screen = """
        › first question
        • first answer
        › second question
        • second answer
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "second answer")
    }

    func testCleanResponse_noRestoreDuringProcessing() {
        // 새 메시지 처리 중(• Working...) 이면 이전 응답을 복원하지 않아야 한다.
        // 이 버그: 연속 요청 시 이전 응답이 그대로 다시 반환되던 문제.
        let screen = """
        › first question
        • first answer is long text
        › second question
        • Working (0s · esc to interrupt)
        › Find and fix a bug in @filename
        """
        // 새 처리가 시작됐으므로 (• Working... → phase 2) 이전 응답을 복원하면 안 됨
        XCTAssertEqual(adapter.cleanResponse(screen), "")
    }

    func testCleanResponse_noRestoreDuringToolExecution() {
        // 도구 실행 중에도 이전 응답을 복원하지 않아야 한다.
        let screen = """
        › hello
        • Hi there
        › list files
        • Running `ls -la`
        › Describe a bug or paste a URL
        """
        // • Running... → isToolLine → phase 2 → 복원 안 함
        XCTAssertEqual(adapter.cleanResponse(screen), "")
    }

    // MARK: - Approval Patterns

    func testApprovalPatterns_notEmpty() {
        XCTAssertFalse(adapter.approvalPatterns.isEmpty)
    }

    func testApprovalPatterns_containsCodexSpecific() {
        let patterns = adapter.approvalPatterns
        let hasCodexPattern = patterns.contains { $0.contains("Would you like to run") }
        XCTAssertTrue(hasCodexPattern)
    }
}
