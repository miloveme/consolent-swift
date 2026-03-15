import XCTest
@testable import Consolent

final class ClaudeCodeAdapterTests: XCTestCase {

    let adapter = ClaudeCodeAdapter()

    // MARK: - fixCJKSpacing Tests

    func testFixCJKSpacing_removePaddingBetweenHangul() {
        // 모든 CJK 문자 뒤에 패딩 1칸
        let input = "안 녕 하 세 요"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "안녕하세요")
    }

    func testFixCJKSpacing_preserveWordBoundary() {
        // 단어 경계: 패딩(1칸) + 실제 공백(1칸) = 2칸
        let input = "최 선 을  다 해"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "최선을 다해")
    }

    func testFixCJKSpacing_sentenceWithPunctuationAndWordBoundaries() {
        // 실제 터미널 패딩 시뮬레이션: "네, 최선을 다해 도와드리겠습니다!"
        // CJK 뒤에 패딩 1칸, 단어 경계는 2칸, 문장부호(half-width)는 패딩 없음
        let input = "네 , 최 선 을  다 해  도 와 드 리 겠 습 니 다 !"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "네, 최선을 다해 도와드리겠습니다!")
    }

    func testFixCJKSpacing_mixedKoreanAndEnglish() {
        // "Swift 코드를 작성합니다" — English 뒤는 패딩 없음
        let input = "Swift 코 드 를  작 성 합 니 다"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "Swift 코드를 작성합니다")
    }

    func testFixCJKSpacing_noChangeForEnglishOnly() {
        let input = "Hello, how are you?"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), input)
    }

    func testFixCJKSpacing_noChangeForNormalKorean() {
        // 패딩이 없는 정상 한국어 — 단어 사이 공백만 존재
        let input = "안녕하세요, 반갑습니다"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), input)
    }

    func testFixCJKSpacing_noChangeForNormalKoreanWithSpaces() {
        // 정상 띄어쓰기가 있는 한국어 (패딩 비율 < 50%)
        let input = "감사합니다! 도움이 필요하면 말씀해 주세요."
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), input)
    }

    func testFixCJKSpacing_japaneseText() {
        let input = "こ ん に ち は"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "こんにちは")
    }

    func testFixCJKSpacing_chineseText() {
        let input = "你 好 世 界"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "你好世界")
    }

    func testFixCJKSpacing_multipleWordBoundaries() {
        // "어떤 프로젝트든 말씀해 주세요"
        let input = "어 떤  프 로 젝 트 든  말 씀 해  주 세 요"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "어떤 프로젝트든 말씀해 주세요")
    }

    func testFixCJKSpacing_multiLine() {
        let input = "안 녕 하 세 요\n반 갑 습 니 다"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "안녕하세요\n반갑습니다")
    }

    func testFixCJKSpacing_punctuationAfterCJK() {
        // CJK + 패딩 + 문장부호: "네!" → 터미널 "네 !" → "네!"
        let input = "네 ! 감 사 합 니 다 ."
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "네! 감사합니다.")
    }

    func testFixCJKSpacing_mixedLinePreservation() {
        // 패딩 있는 줄과 없는 줄 혼합
        let padded = "안 녕 하 세 요"      // 패딩 있음 → fix
        let normal = "Hello world"          // 패딩 없음 → 유지
        let input = padded + "\n" + normal
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), "안녕하세요\nHello world")
    }

    func testFixCJKSpacing_singleCJKChar() {
        // CJK 1개 → cjkCount < 2 → 무시
        let input = "I am 개"
        XCTAssertEqual(CJKSpacingFix.fixCJKSpacing(input), input)
    }

    // MARK: - isCJK Tests

    func testIsCJK_hangulSyllable() {
        XCTAssertTrue(CJKSpacingFix.isCJK("가"))
        XCTAssertTrue(CJKSpacingFix.isCJK("힣"))
        XCTAssertTrue(CJKSpacingFix.isCJK("안"))
    }

    func testIsCJK_cjkIdeograph() {
        XCTAssertTrue(CJKSpacingFix.isCJK("你"))
        XCTAssertTrue(CJKSpacingFix.isCJK("好"))
    }

    func testIsCJK_hiraganaKatakana() {
        XCTAssertTrue(CJKSpacingFix.isCJK("あ"))
        XCTAssertTrue(CJKSpacingFix.isCJK("ア"))
    }

    func testIsCJK_nonCJK() {
        XCTAssertFalse(CJKSpacingFix.isCJK("A"))
        XCTAssertFalse(CJKSpacingFix.isCJK("1"))
        XCTAssertFalse(CJKSpacingFix.isCJK(" "))
        XCTAssertFalse(CJKSpacingFix.isCJK("!"))
    }

    // MARK: - cleanResponse: State Machine Tests

    func testCleanResponse_extractsAssistantResponseAfterMarker() {
        let screen = """
        ❯ hello
        ⏺ 안녕하세요, 무엇을 도와드릴까요?
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요, 무엇을 도와드릴까요?")
    }

    func testCleanResponse_skipsUserInputBetweenPromptAndResponse() {
        // OpenClaw JSON 메타데이터 + 사용자 입력 echo → 전부 스킵
        let screen = """
        ❯ {"message_id": "87", "sender_id": "123"}
        Sender (untrusted metadata):
        {"label": "Jun", "id": "123"}
        이제 코딩을 잘할것 같아
        ⏺ 감사합니다! 도움이 필요하면 말씀해 주세요.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "감사합니다! 도움이 필요하면 말씀해 주세요.")
    }

    func testCleanResponse_lastTurnOnly() {
        let screen = """
        ❯ first question
        ⏺ first answer
        ❯ second question
        ⏺ second answer
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "second answer")
    }

    func testCleanResponse_filtersTUIChrome_triangleMarkers() {
        let screen = """
        ❯ hello
        ⏺ 응답입니다
        ►► bypass permissions on (shift+tab to cycle)
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답입니다")
    }

    func testCleanResponse_filtersTUIChrome_statusBar() {
        let screen = """
        ❯ hello
        ⏺ 테스트 응답
        ⏵⏵ auto-accept edits
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "테스트 응답")
    }

    func testCleanResponse_filtersToolUseIndicators() {
        let screen = """
        ❯ read the file
        ⏺ Read src/main.swift (ctrl+r to expand)
        ⏺ 파일 내용을 확인했습니다.

        코드가 정상입니다.
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("파일 내용을 확인했습니다."))
        XCTAssertTrue(result.contains("코드가 정상입니다."))
        XCTAssertFalse(result.contains("Read src/main.swift"))
    }

    func testCleanResponse_filtersSeparatorLines() {
        let screen = """
        ❯ hello
        ⏺ 첫 번째 줄
        ───────────────────
        두 번째 줄
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("첫 번째 줄"))
        XCTAssertTrue(result.contains("두 번째 줄"))
        XCTAssertFalse(result.contains("───"))
    }

    func testCleanResponse_filtersSpinnerLines() {
        let screen = """
        ❯ hello
        ⠋⠙⠹
        ⏺ 응답 완료
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답 완료")
    }

    func testCleanResponse_filtersWelcomeScreenBoxBorders() {
        let screen = """
        ╭─────────────────────╮
        │  Welcome to Claude  │
        ╰─────────────────────╯
        ❯ hi
        ⏺ 안녕하세요!
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요!")
    }

    func testCleanResponse_filtersTokenUsageLines() {
        let screen = """
        ❯ hello
        ⏺ 응답
        12.5k tokens
        3 tool use
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    func testCleanResponse_filtersEscToInterrupt() {
        let screen = """
        ❯ hello
        ⏺ 긴 응답입니다
        esc to interrupt
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "긴 응답입니다")
    }

    func testCleanResponse_preservesMultilineResponse() {
        let screen = """
        ❯ explain
        ⏺ 첫 번째 단락입니다.

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
        ❯ hello
        some echo text
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "")
    }

    func testCleanResponse_promptOnlyLines() {
        let screen = """
        ›
        ❯
        >
        $
        ❯ actual input
        ⏺ response
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "response")
    }

    func testCleanResponse_nullCharacterRemoval() {
        let screen = "❯ hello\n⏺ 안\u{0000}녕\u{0000}하\u{0000}세\u{0000}요"
        XCTAssertEqual(adapter.cleanResponse(screen), "안녕하세요")
    }

    func testCleanResponse_filtersNativeInstallationWarning() {
        let screen = """
        ❯ hello
        ⏺ 응답
        Native installation exists but ~/.local/bin is not in PATH
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "응답")
    }

    // MARK: - cleanResponse: CJK Spacing Integration

    func testCleanResponse_cjkPaddingInResponse() {
        // 전체 파이프라인 통합: TUI 파싱 + 패딩 제거
        let screen = """
        ❯ 안 녕
        ⏺ 안 녕 하 세 요 , 무 엇 을  도 와 드 릴 까 요 ?
        """
        let result = adapter.cleanResponse(screen)
        XCTAssertEqual(result, "안녕하세요, 무엇을 도와드릴까요?")
    }

    func testCleanResponse_normalKoreanPreserved() {
        // 패딩 없는 정상 한국어 → 공백 유지
        let screen = """
        ❯ hello
        ⏺ 감사합니다! 도움이 필요하면 말씀해 주세요.
        """
        XCTAssertEqual(adapter.cleanResponse(screen), "감사합니다! 도움이 필요하면 말씀해 주세요.")
    }
}
