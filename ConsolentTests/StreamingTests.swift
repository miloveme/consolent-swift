import XCTest
@testable import Consolent

final class StreamingTests: XCTestCase {

    // MARK: - lightweightTUIChromeFilter Tests

    func testFilter_normalContent() {
        let input = "Hello, world!\nThis is a response."
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertEqual(result, input)
    }

    func testFilter_escToInterrupt() {
        let input = "Some response text\n  esc to interrupt\nMore text"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertTrue(result.contains("Some response text"))
        XCTAssertTrue(result.contains("More text"))
        XCTAssertFalse(result.contains("esc to interrupt"))
    }

    func testFilter_escToCancel() {
        let input = "Response\n esc to cancel \nContent"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("esc to cancel"))
        XCTAssertTrue(result.contains("Response"))
        XCTAssertTrue(result.contains("Content"))
    }

    func testFilter_shortcuts() {
        let input = "Line1\n? for shortcuts\nLine2"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("? for shortcuts"))
    }

    func testFilter_statusBarMarkers() {
        // 상태바 삼각형 문자로 시작하는 줄
        let input = "Response text\n▶ Claude Code 3.5\n⏸ Paused\nContent"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("▶ Claude Code"))
        XCTAssertFalse(result.contains("⏸ Paused"))
        XCTAssertTrue(result.contains("Response text"))
        XCTAssertTrue(result.contains("Content"))
    }

    func testFilter_tokenCount() {
        let input = "Hello\n1.5k tokens\n42 tokens\nWorld"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("tokens"))
        XCTAssertTrue(result.contains("Hello"))
        XCTAssertTrue(result.contains("World"))
    }

    func testFilter_thinkingStreaming() {
        let input = "Thinking…\nActual response\nStreaming…"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("Thinking…"))
        XCTAssertFalse(result.contains("Streaming…"))
        XCTAssertTrue(result.contains("Actual response"))
    }

    func testFilter_preservesEmptyLines() {
        let input = "Line1\n\nLine2"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertEqual(result, "Line1\n\nLine2")
    }

    func testFilter_typeYourMessage() {
        let input = "* Type your message\nResponse content"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("Type your message"))
        XCTAssertTrue(result.contains("Response content"))
    }

    func testFilter_shiftTab() {
        let input = "Content\n  shift+tab to cycle\nMore"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("shift+tab"))
    }

    func testFilter_emptyInput() {
        XCTAssertEqual(Session.lightweightTUIChromeFilter(""), "")
    }

    func testFilter_onlyChromeLines() {
        let input = "esc to interrupt\n? for shortcuts\n42 tokens"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertTrue(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    // MARK: - Thinking Indicator Filter Tests

    func testFilter_spinnerPrefixLine() {
        let input = "Response\n✻ Discombobulating…\nMore text"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("Discombobulating"))
        XCTAssertTrue(result.contains("Response"))
        XCTAssertTrue(result.contains("More text"))
    }

    func testFilter_thinkingWithEffort() {
        let input = "Content\n(thinking with high effort)\nMore"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("thinking with"))
        XCTAssertTrue(result.contains("Content"))
    }

    func testFilter_thinkingWithEffortNoParen() {
        // TUI 리드로우로 ( 없이 나오는 케이스
        let input = "Content\nthinking with high effort\nMore"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("thinking with"))
    }

    func testFilter_concatenatedThinking() {
        // 빠른 TUI 리드로우로 연속 문자열
        let input = "effortthinking with high effortthinking with high effort"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertTrue(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func testFilter_ctrlExpandHint() {
        let input = "Text\nRead file.swift (ctrl+o to expand)\nMore"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("ctrl+o to expand"))
    }

    func testFilter_toolOutputPrefix() {
        let input = "Response\n⎿ $ ls /Users/test\n⎿ output line\nMore"
        let result = Session.lightweightTUIChromeFilter(input)
        XCTAssertFalse(result.contains("⎿"))
        XCTAssertTrue(result.contains("Response"))
        XCTAssertTrue(result.contains("More"))
    }

    func testFilter_variousSpinnerChars() {
        let spinners = ["✳ Loading", "✶ Pondering", "✽ Working", "✢ Thinking", "· processing"]
        for spinner in spinners {
            let result = Session.lightweightTUIChromeFilter(spinner)
            XCTAssertTrue(result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                          "Should filter: \(spinner)")
        }
    }

    // MARK: - filterStreamingNoise Tests

    func testStreamingNoise_removesToolOutput() {
        let input = "Here is the answer.\n⎿ $ ls -la\n⎿ file1.txt\nMore content."
        let result = Session.filterStreamingNoise(input)
        XCTAssertTrue(result.contains("Here is the answer."))
        XCTAssertTrue(result.contains("More content."))
        XCTAssertFalse(result.contains("⎿"))
    }

    func testStreamingNoise_preservesNormalContent() {
        let input = "Line one.\nLine two.\nLine three."
        let result = Session.filterStreamingNoise(input)
        XCTAssertEqual(result, input)
    }

    func testStreamingNoise_emptyInput() {
        XCTAssertEqual(Session.filterStreamingNoise(""), "")
    }

    // MARK: - ClaudeCodeAdapter.isThinkingIndicator Tests

    func testThinkingIndicator_spinnerWithWord() {
        XCTAssertTrue(ClaudeCodeAdapter.isThinkingIndicator("✻ Discombobulating…"))
        XCTAssertTrue(ClaudeCodeAdapter.isThinkingIndicator("✶ Cogitating…"))
        XCTAssertTrue(ClaudeCodeAdapter.isThinkingIndicator("· (thinking with high effort)"))
    }

    func testThinkingIndicator_thinkingEffort() {
        XCTAssertTrue(ClaudeCodeAdapter.isThinkingIndicator("(thinking with high effort)"))
        XCTAssertTrue(ClaudeCodeAdapter.isThinkingIndicator("(thinking with standard effort)"))
    }

    func testThinkingIndicator_normalText() {
        XCTAssertFalse(ClaudeCodeAdapter.isThinkingIndicator("Here is the answer"))
        XCTAssertFalse(ClaudeCodeAdapter.isThinkingIndicator("The function returns a value"))
    }

    func testThinkingIndicator_empty() {
        XCTAssertFalse(ClaudeCodeAdapter.isThinkingIndicator(""))
        XCTAssertFalse(ClaudeCodeAdapter.isThinkingIndicator("   "))
    }

    // MARK: - ClaudeCodeAdapter.cleanResponse Thinking Filter Tests

    func testCleanResponse_filtersThinkingOnMarkerLine() {
        let adapter = ClaudeCodeAdapter()
        let screen = "❯ explain this\n⏺ ✻ Discombobulating… (thinking with high effort)"
        let result = adapter.cleanResponse(screen)
        XCTAssertEqual(result, "")
    }

    func testCleanResponse_preservesRealResponse() {
        let adapter = ClaudeCodeAdapter()
        let screen = "❯ explain this\n⏺ Here is the actual response.\nIt continues here."
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("Here is the actual response."))
        XCTAssertTrue(result.contains("It continues here."))
    }

    func testCleanResponse_filtersThinkingBelowMarker() {
        let adapter = ClaudeCodeAdapter()
        let screen = "❯ explain\n⏺\n(thinking with high effort)\n✻ Pondering…"
        let result = adapter.cleanResponse(screen)
        XCTAssertEqual(result, "")
    }

    // MARK: - GeminiAdapter Spacing Fix Tests

    func testGeminiCleanResponse_preservesSpaces() {
        let adapter = GeminiAdapter()
        // Null 문자가 공백으로 치환되어 단어 사이 띄어쓰기가 보존되는지 확인
        let screen = "✦ Hello\u{0000}world\u{0000}this\u{0000}is\u{0000}a\u{0000}test"
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("Hello"), "응답에 Hello 포함되어야 함")
        XCTAssertTrue(result.contains(" "), "단어 사이에 공백이 있어야 함")
        XCTAssertFalse(result.contains("\u{0000}"), "null 문자가 남아있으면 안 됨")
    }

    func testGeminiCleanResponse_basicResponse() {
        let adapter = GeminiAdapter()
        let screen = "> user message\n✦ Here is the response.\nSecond line."
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("Here is the response."))
        XCTAssertTrue(result.contains("Second line."))
    }

    func testGeminiCleanResponse_filtersTUIChrome() {
        let adapter = GeminiAdapter()
        let screen = "✦ Response text\nesc to cancel\nMore response"
        let result = adapter.cleanResponse(screen)
        XCTAssertTrue(result.contains("Response text"))
        XCTAssertFalse(result.contains("esc to cancel"))
    }

    // MARK: - StreamEvent Enum Tests

    func testStreamEvent_delta() {
        let event = Session.StreamEvent.delta("Hello")
        if case .delta(let text) = event {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected .delta")
        }
    }

    func testStreamEvent_error() {
        let event = Session.StreamEvent.error("Something went wrong")
        if case .error(let msg) = event {
            XCTAssertEqual(msg, "Something went wrong")
        } else {
            XCTFail("Expected .error")
        }
    }
}
