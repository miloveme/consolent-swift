import XCTest
@testable import Consolent

final class GeminiAdapterTests: XCTestCase {

    let adapter = GeminiAdapter()

    // MARK: - Properties

    func testProperties() {
        XCTAssertEqual(adapter.name, "Gemini")
        XCTAssertEqual(adapter.modelId, "gemini")
        XCTAssertEqual(adapter.exitCommand, "/quit")
        XCTAssertEqual(adapter.readySignal, "Type your message")
        XCTAssertEqual(adapter.processingSignal, "esc\\s+to\\s+cancel")
        XCTAssertEqual(adapter.defaultBinaryName, "gemini")
    }

    // MARK: - buildCommand

    func testBuildCommand_basic() {
        let cmd = adapter.buildCommand(binaryPath: "/opt/homebrew/bin/gemini", args: [], autoApprove: false)
        XCTAssertEqual(cmd, "/opt/homebrew/bin/gemini")
    }

    func testBuildCommand_autoApprove() {
        let cmd = adapter.buildCommand(binaryPath: "/opt/homebrew/bin/gemini", args: [], autoApprove: true)
        XCTAssertEqual(cmd, "/opt/homebrew/bin/gemini -y")
    }

    func testBuildCommand_withArgs() {
        let cmd = adapter.buildCommand(binaryPath: "/opt/homebrew/bin/gemini", args: ["-m", "gemini-2.5-pro"], autoApprove: false)
        XCTAssertEqual(cmd, "/opt/homebrew/bin/gemini -m gemini-2.5-pro")
    }

    func testBuildCommand_autoApproveWithArgs() {
        let cmd = adapter.buildCommand(binaryPath: "/opt/homebrew/bin/gemini", args: ["--sandbox"], autoApprove: true)
        XCTAssertEqual(cmd, "/opt/homebrew/bin/gemini -y --sandbox")
    }

    // MARK: - isResponseComplete

    func testIsResponseComplete_readyWithPlaceholder() {
        // 입력 플레이스홀더 → 응답 완료
        let buffer = "▀▀▀▀▀▀▀▀▀▀▀\n*  Type your message or @path/to/file\n▄▄▄▄▄▄▄▄▄▄▄\n/model Auto (Gemini 3)"
        XCTAssertTrue(adapter.isResponseComplete(screenBuffer: buffer))
    }

    func testIsResponseComplete_readyWithBlockBarAndModel() {
        // 플레이스홀더 없어도 입력 영역 + /model → 응답 완료
        let buffer = "▀▀▀▀▀▀▀▀▀▀▀\n* \n▄▄▄▄▄▄▄▄▄▄▄\n/model Auto (Gemini 3)"
        XCTAssertTrue(adapter.isResponseComplete(screenBuffer: buffer))
    }

    func testIsResponseComplete_processingSignalPresent() {
        // esc to cancel → 처리 중
        let buffer = "✦ 생성 중...\nesc to cancel\n/model Auto"
        XCTAssertFalse(adapter.isResponseComplete(screenBuffer: buffer))
    }

    func testIsResponseComplete_noInputArea() {
        // 입력 영역(▀▀▀/▄▄▄) 없음 → 완료 아님 (처리 중이거나 아직 표시 안됨)
        let buffer = "* hello\n/model Auto (Gemini 3)"
        XCTAssertFalse(adapter.isResponseComplete(screenBuffer: buffer))
    }

    func testIsResponseComplete_noSignals() {
        // 입력 영역 없음, /model 없음 → 완료 아님
        let buffer = "Loading...\nPlease wait..."
        XCTAssertFalse(adapter.isResponseComplete(screenBuffer: buffer))
    }

    // MARK: - cleanResponse: State Machine

    func testCleanResponse_extractsAssistantResponseAfterMarker() {
        let screen = """
        > hello
        ✦ 안녕하세요, 무엇을 도와드릴까요?
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요, 무엇을 도와드릴까요?")
    }

    func testCleanResponse_skipsUserInputBetweenPromptAndResponse() {
        let screen = """
        > 코드를 작성해줘
        user metadata here
        some echo text
        ✦ 네, 코드를 작성하겠습니다.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "네, 코드를 작성하겠습니다.")
    }

    func testCleanResponse_lastTurnOnly() {
        let screen = """
        > first question
        ✦ first answer
        > second question
        ✦ second answer
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "second answer")
    }

    func testCleanResponse_preservesMultilineResponse() {
        let screen = """
        > explain
        ✦ 첫 번째 단락입니다.

        두 번째 단락입니다.

        세 번째 단락입니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("첫 번째 단락입니다."))
        XCTAssertTrue(result.contains("두 번째 단락입니다."))
        XCTAssertTrue(result.contains("세 번째 단락입니다."))
    }

    func testCleanResponse_emptyScreen() {
        XCTAssertEqual(adapter.cleanResponse(""), "")
    }

    func testCleanResponse_noAssistantResponse() {
        let screen = """
        > hello
        some echo text
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "")
    }

    // MARK: - cleanResponse: Shell Mode / YOLO Mode

    func testCleanResponse_shellModeInputPrefix() {
        let screen = """
        ! ls -la
        drwxr-xr-x  5 user  staff  160 Jan  1 00:00 .
        ✦ 디렉토리 내용을 보여드리겠습니다.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "디렉토리 내용을 보여드리겠습니다.")
    }

    func testCleanResponse_yoloModeInputPrefix() {
        let screen = """
        * run all tests
        ✦ 테스트를 실행하겠습니다.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "테스트를 실행하겠습니다.")
    }

    // MARK: - cleanResponse: TUI Chrome Filtering

    func testCleanResponse_filtersEscToCancel() {
        let screen = """
        > hello
        ✦ 응답입니다
        esc to cancel
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답입니다")
    }

    func testCleanResponse_filtersShortcutsHint() {
        let screen = """
        > hello
        ✦ 응답입니다
        ? for shortcuts
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답입니다")
    }

    func testCleanResponse_filtersPressTabTwice() {
        let screen = """
        > hello
        ✦ 응답입니다
        press tab twice for more
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답입니다")
    }

    func testCleanResponse_filtersApprovalMode() {
        let screen = """
        > hello
        ✦ 응답입니다
        YOLO mode
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답입니다")
    }

    func testCleanResponse_filtersExitWarning() {
        let screen = """
        > hello
        ✦ 응답
        Press Ctrl+C again to exit
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersLoadingPhrases() {
        let screen = """
        > hello
        I'm Feeling Lucky
        ✦ 응답 완료
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답 완료")
    }

    func testCleanResponse_filtersTokenUsageLines() {
        let screen = """
        > hello
        ✦ 응답
        12.5k tokens
        3 tool use
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersLoadedCredentials() {
        let screen = """
        Loaded cached credentials.
        > hello
        ✦ 응답
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    // MARK: - cleanResponse: Visual Element Filtering

    func testCleanResponse_separatorEndsResponsePhase() {
        // 구분선(───) 이후는 TUI chrome 영역 → 응답에 포함되지 않음
        let screen = """
        > hello
        ✦ 첫 번째 줄
        ───────────────────
        YOLO ctrl+y
        - 2 skills
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("첫 번째 줄"))
        XCTAssertFalse(result.contains("YOLO"))
        XCTAssertFalse(result.contains("skills"))
        XCTAssertFalse(result.contains("───"))
    }

    func testCleanResponse_filtersSpinnerLines() {
        let screen = """
        > hello
        ⠋⠙⠹
        ✦ 응답 완료
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답 완료")
    }

    func testCleanResponse_filtersBoxBorderLines() {
        let screen = """
        > hello
        ✦ 응답
        ╭──────────────╮
        │ Shell Command │
        ╰──────────────╯
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersAsciiArtHeader() {
        let screen = """
        ▝▜▄
        ▗▟▀
        █░░░░█ Gemini CLI
        > hello
        ✦ 응답
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersToolStatusLines() {
        let screen = """
        > read file
        ✦ 파일을 읽겠습니다.
        ✓ ReadFile src/main.swift
        ⊷ Shell ls -la
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertEqual(result, "파일을 읽겠습니다.")
    }

    func testCleanResponse_filtersPromptOnlyLines() {
        let screen = """
        >
        !
        *
        $
        > actual input
        ✦ response
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "response")
    }

    // MARK: - cleanResponse: Null Characters

    func testCleanResponse_nullCharacterRemoval() {
        let screen = "> hello\n✦ 안\u{0000}녕\u{0000}하\u{0000}세\u{0000}요"
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요")
    }

    func testCleanResponse_deleteCharacterRemoval() {
        let screen = "> hello\n✦ test\u{007F}response"
        XCTAssertEqual(adapter.cleanResponse(screen), "testresponse")
    }

    // MARK: - cleanResponse: CJK Integration

    func testCleanResponse_cjkPaddingInResponse() {
        let screen = """
        > 안 녕
        ✦ 안 녕 하 세 요 , 무 엇 을  도 와 드 릴 까 요 ?
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요, 무엇을 도와드릴까요?")
    }

    func testCleanResponse_normalKoreanPreserved() {
        let screen = """
        > hello
        ✦ 감사합니다! 도움이 필요하면 말씀해 주세요.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "감사합니다! 도움이 필요하면 말씀해 주세요.")
    }

    // MARK: - cleanResponse: Context/Model Lines

    func testCleanResponse_filtersContextLine() {
        let screen = """
        > hello
        ✦ 응답
        context: 1234/32000 tokens
        model: gemini-2.5-pro
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    // MARK: - cleanResponse: TUI Chrome 패턴이 응답에 포함되는 경우

    func testCleanResponse_responseContainingGeminiCLI() {
        // Gemini가 자기 소개할 때 "Gemini CLI"가 응답에 포함되는 경우
        // "gemini cli"는 TUI chrome 패턴이지만, ✦ 마커 뒤의 응답 내용은 필터하면 안 됨
        let screen = """
        > 너는 누구야
        ✦ 저는 소프트웨어 엔지니어링 작업을 지원하는 Gemini CLI입니다.
        코드 구현, 시스템 분석, 테스트를 돕습니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("Gemini CLI"), "응답 내 'Gemini CLI' 텍스트가 보존되어야 함")
        XCTAssertTrue(result.contains("코드 구현"), "응답 연속 줄이 보존되어야 함")
    }

    func testCleanResponse_responseContainingCodeAssist() {
        // "code assist in" 패턴이 응답에 포함되는 경우
        let screen = """
        > 기능 설명해줘
        ✦ code assist in your IDE에서 자동 완성을 제공합니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("code assist in"), "응답 내 'code assist in' 텍스트가 보존되어야 함")
    }

    func testCleanResponse_tuiChromeStillFilteredOutsidePhase2() {
        // phase 2 밖에서는 TUI chrome이 여전히 필터되어야 함
        let screen = """
        Gemini CLI v1.0
        loaded cached credentials
        > hello
        ✦ 안녕하세요!
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertEqual(result, "안녕하세요!")
        XCTAssertFalse(result.contains("Gemini CLI v1.0"))
        XCTAssertFalse(result.contains("loaded cached credentials"))
    }

    // MARK: - 실제 화면 버퍼 재현 테스트

    func testCleanResponse_fullScreenWithInputPlaceholder() {
        // 실제 Gemini 화면 버퍼 재현: 응답 후 입력 필드 플레이스홀더가
        // "* Type your message"로 시작하여 hasPrefix("* ")에 매칭되는 경우
        let screen = """
          ▝▜▄     Gemini CLI v0.33.1
            ▝▜▄
           ▗▟▀    Logged in with Google /auth
          ▝▀      Gemini Code Assist in Google One AI Pro /upgrade

        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         > Say just the word OK and nothing else.
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
        ✦ OK

        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         > Say just the word OK and nothing else.
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
        ✦ OK

                                                          ? for shortcuts
        ──────────────────────────────────────────────────────────────────
         YOLO ctrl+y                                  1 GEMINI.md file | 1 MCP server | 2 skills
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         *   Type your message or @path/to/file
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
         ~/Documents/Dev/AI/gemini                     no sandbox (see /docs)                      /model Auto (Gemini 3)
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertEqual(result, "OK", "입력 필드 플레이스홀더 '* Type your message'가 응답을 클리어하면 안 됨")
    }

    func testCleanResponse_whoAreYouResponse() {
        // "너는 누구야" 질문에 대한 Gemini 자기소개 응답
        // 응답에 "Gemini CLI", "code assist" 등 TUI chrome 패턴이 포함될 수 있음
        let screen = """
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         > 너는 누구야
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
        ✦ 저는 Google의 Gemini CLI입니다. 소프트웨어 엔지니어링 작업을 도와드립니다.
        코드 작성, 디버깅, 코드 리뷰, 시스템 설계 등을 지원합니다.

                                                          ? for shortcuts
        ──────────────────────────────────────────────────────────────────
         YOLO ctrl+y                                  1 GEMINI.md file
        ▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
         *   Type your message or @path/to/file
        ▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄
         ~/Documents/Dev/AI/gemini                     /model Auto (Gemini 3)
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("Gemini CLI"), "응답 내 'Gemini CLI'가 보존되어야 함")
        XCTAssertTrue(result.contains("코드 작성"), "응답 연속 줄이 보존되어야 함")
        XCTAssertFalse(result.contains("Type your message"), "입력 필드 플레이스홀더는 제거되어야 함")
        XCTAssertFalse(result.contains("YOLO ctrl"), "TUI chrome은 제거되어야 함")
    }
}
