import XCTest
@testable import Consolent

// MARK: - Fixture 모델

/// 로그에서 추출한 회귀 테스트 fixture 파일 형식.
/// `tools/extract_fixtures.py`가 생성하고, 이 테스트가 로드한다.
///
/// ## Fixture 라이프사이클
///
/// ```
/// [추출] → status: "open"
///   문제 발생 시 `python3 tools/extract_fixtures.py`로 생성.
///   expectedCleanText는 어댑터의 현재 (버그 포함) 출력.
///   품질 테스트(노이즈, 중복, 잘림)가 문제를 감지하면 실패.
///
/// [교정] → status: "open", corrected: true
///   expectedCleanText를 올바른 기대값으로 수동 수정.
///   testCorrectedFixtures가 어댑터를 고칠 때까지 실패.
///
/// [해결] → status: "resolved"
///   어댑터 수정 후 모든 테스트 통과.
///   회귀 방지를 위해 영구 보관.
///   `python3 tools/extract_fixtures.py --status` 로 상태 확인.
///
/// [정리]
///   같은 코드 경로를 테스트하는 resolved fixture가 여러 개면
///   대표 1개만 남기고 나머지 삭제.
///   `python3 tools/extract_fixtures.py --status --cleanup` 으로 정리.
/// ```
private struct FixtureFile: Decodable {
    let metadata: Metadata
    let cases: [FixtureCase]

    struct Metadata: Decodable {
        let source: String
        let sessionId: String
        let cliType: String
        let description: String
        /// "open" (미해결), "resolved" (해결됨, 회귀 방지용 보관)
        let status: String?
    }

    struct FixtureCase: Decodable {
        let id: String
        let type: String              // "sync" | "streaming"
        let message: String
        let adapterType: String       // "ClaudeCodeAdapter" | "GeminiAdapter" | "CodexAdapter"
        let screenText: String
        let expectedCleanText: String
        let completionSignal: String
        let wasEmpty: Bool
        let hasError: Bool

        // 품질 감지 (옵션)
        let suspicious: Bool?
        let suspiciousReasons: [String]?

        /// true면 expectedCleanText가 수동 교정됨 → cleanResponse 결과와 비교.
        /// false/nil이면 스크립트가 추출한 그대로 → 품질 검증만 수행.
        let corrected: Bool?

        // 스트리밍 전용 (옵션)
        let baseline: String?
        let pollCount: Int?
        let totalDeltaLength: Int?
        let streamingDeltas: [String]?
    }
}

// MARK: - RegressionTests

/// 로그 기반 회귀 테스트.
///
/// 두 종류의 검증을 수행한다:
///
/// ## 1. 교정된 fixture (`corrected: true`)
/// `expectedCleanText`가 사람이 수정한 올바른 기대값.
/// `adapter.cleanResponse(screenText) == expectedCleanText` 비교.
/// → 어댑터가 고쳐질 때까지 **테스트 실패**.
///
/// ## 2. 미교정 fixture (`corrected: false` 또는 미지정)
/// `expectedCleanText`는 현재 어댑터 출력 (버그 포함).
/// 대신 응답 내 TUI 노이즈, 중복, 잘림 등을 직접 검사.
/// → 품질 문제가 있으면 **테스트 실패**.
final class RegressionTests: XCTestCase {

    /// Fixtures 디렉토리 내 모든 fixture 파일 경로
    private static var fixtureURLs: [URL] = {
        let bundle = Bundle(for: RegressionTests.self)
        guard let resourceURL = bundle.resourceURL else { return [] }

        let fixturesDir = resourceURL.appendingPathComponent("Fixtures")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: fixturesDir,
            includingPropertiesForKeys: nil
        ) {
            return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("fixture_") }
        }

        return findFixturesInSourceDir()
    }()

    private static func findFixturesInSourceDir() -> [URL] {
        let fm = FileManager.default

        if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
            let fixturesDir = URL(fileURLWithPath: srcRoot)
                .appendingPathComponent("ConsolentTests/Fixtures")
            if let files = try? fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil) {
                return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("fixture_") }
            }
        }

        let thisFile = URL(fileURLWithPath: #file)
        let fixturesDir = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
        if let files = try? fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil) {
            return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("fixture_") }
        }

        return []
    }

    private func createAdapter(type: String) -> CLIAdapter? {
        switch type {
        case "ClaudeCodeAdapter": return ClaudeCodeAdapter()
        case "GeminiAdapter":    return GeminiAdapter()
        case "CodexAdapter":     return CodexAdapter()
        default:                 return nil
        }
    }

    // MARK: - 교정된 fixture 회귀 테스트

    /// `corrected: true`인 케이스만 검증.
    /// expectedCleanText가 사람이 교정한 올바른 값이므로,
    /// adapter.cleanResponse()가 이와 다르면 테스트 실패.
    func testCorrectedFixtures() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else {
            print("[RegressionTests] fixture 파일 없음 — 건너뜀")
            return
        }

        var totalCorrected = 0
        var failures: [(file: String, caseId: String, message: String)] = []

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases where testCase.corrected == true {
                totalCorrected += 1

                guard let adapter = createAdapter(type: testCase.adapterType) else {
                    failures.append((url.lastPathComponent, testCase.id, "알 수 없는 어댑터: \(testCase.adapterType)"))
                    continue
                }

                let actual = adapter.cleanResponse(testCase.screenText)

                if actual != testCase.expectedCleanText {
                    failures.append((
                        file: url.lastPathComponent,
                        caseId: testCase.id,
                        message: """
                        cleanResponse 불일치
                        메시지: "\(testCase.message)"
                        기대 (\(testCase.expectedCleanText.count)자): \(preview(testCase.expectedCleanText))
                        실제 (\(actual.count)자): \(preview(actual))
                        """
                    ))
                }
            }
        }

        if totalCorrected == 0 {
            print("[RegressionTests] 교정된 fixture 없음 — 건너뜀")
            return
        }

        print("[RegressionTests] 교정된 fixture: \(totalCorrected - failures.count)/\(totalCorrected) 통과")

        if !failures.isEmpty {
            let report = failures.map { "[\($0.file)] \($0.caseId):\n\($0.message)" }
                .joined(separator: "\n\n")
            XCTFail("교정된 fixture 회귀 실패 \(failures.count)건:\n\n\(report)")
        }
    }

    // MARK: - TUI 노이즈 검증 (실패하는 테스트)

    /// 모든 fixture에서 cleanResponse 결과에 TUI 노이즈가 남아있으면 실패.
    /// 어댑터의 cleanResponse가 TUI chrome을 완전히 제거해야 통과.
    func testNoTUINoiseInCleanResponse() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        // TUI 노이즈로 간주하는 패턴
        let noisePatterns: [(pattern: String, label: String)] = [
            ("esc to interrupt",   "처리중 표시"),
            ("esc to cancel",      "처리중 표시"),
            ("? for shortcuts",    "준비상태 표시"),
            ("shift+tab to cycle", "UI 힌트"),
            ("Tip: Use /",         "Claude 팁"),
        ]

        var failures: [(file: String, caseId: String, noise: String)] = []

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases {
                guard let adapter = createAdapter(type: testCase.adapterType) else { continue }

                let actual = adapter.cleanResponse(testCase.screenText)
                let lower = actual.lowercased()

                for (pattern, label) in noisePatterns {
                    if lower.contains(pattern.lowercased()) {
                        failures.append((url.lastPathComponent, testCase.id, "\(label): \"\(pattern)\""))
                    }
                }
            }
        }

        if !failures.isEmpty {
            let report = failures.map { "[\($0.file)] \($0.caseId) — \($0.noise)" }
                .joined(separator: "\n")
            XCTFail("cleanResponse에 TUI 노이즈 잔존 \(failures.count)건:\n\(report)")
        }
    }

    // MARK: - 내용 중복 검증 (실패하는 테스트)

    /// cleanResponse 결과에서 동일 문장이 반복되면 실패.
    func testNoDuplicatedContent() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        var failures: [(file: String, caseId: String, duplicated: String)] = []

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases {
                guard let adapter = createAdapter(type: testCase.adapterType) else { continue }

                let actual = adapter.cleanResponse(testCase.screenText)
                guard actual.count > 40 else { continue }

                let duplicates = findDuplicatedLines(actual, minLength: 20)
                if !duplicates.isEmpty {
                    failures.append((
                        url.lastPathComponent,
                        testCase.id,
                        "\(duplicates.count)건: \"\(String(duplicates[0].prefix(50)))...\""
                    ))
                }
            }
        }

        if !failures.isEmpty {
            let report = failures.map { "[\($0.file)] \($0.caseId) — \($0.duplicated)" }
                .joined(separator: "\n")
            XCTFail("cleanResponse에 내용 중복 \(failures.count)건:\n\(report)")
        }
    }

    // MARK: - 코드 펜스 검증 (실패하는 테스트)

    /// cleanResponse에 열린 코드 펜스가 닫히지 않으면 실패 (잘린 응답).
    func testCodeFencesBalanced() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        var failures: [(file: String, caseId: String, count: Int)] = []

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases {
                guard let adapter = createAdapter(type: testCase.adapterType) else { continue }

                let actual = adapter.cleanResponse(testCase.screenText)
                let fenceCount = actual.components(separatedBy: "```").count - 1

                if fenceCount > 0 && fenceCount % 2 != 0 {
                    failures.append((url.lastPathComponent, testCase.id, fenceCount))
                }
            }
        }

        if !failures.isEmpty {
            let report = failures.map { "[\($0.file)] \($0.caseId) — 코드 펜스 \($0.count)개 (홀수)" }
                .joined(separator: "\n")
            XCTFail("코드 펜스 미닫힘 \(failures.count)건:\n\(report)")
        }
    }

    // MARK: - 스트리밍 델타 연속성 테스트

    /// 스트리밍 케이스에서 델타를 이어붙인 결과가 최종 응답과 유사한지 검증.
    func testStreamingDeltas_consistency() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases where testCase.type == "streaming" {
                guard let deltas = testCase.streamingDeltas, !deltas.isEmpty else { continue }

                let realDeltas = deltas.filter { !$0.hasPrefix("...") }
                let accumulated = realDeltas.joined()

                if !testCase.expectedCleanText.isEmpty && !accumulated.isEmpty {
                    let similarity = stringSimilarity(accumulated, testCase.expectedCleanText)
                    if similarity < 0.5 {
                        XCTFail("""
                        [\(url.lastPathComponent)] \(testCase.id): 스트리밍 델타 불일치
                        누적 델타 (\(accumulated.count)자): \(preview(accumulated))
                        최종 응답 (\(testCase.expectedCleanText.count)자): \(preview(testCase.expectedCleanText))
                        유사도: \(String(format: "%.1f%%", similarity * 100))
                        """)
                    }
                }
            }
        }
    }

    // MARK: - completionSignal 일관성 테스트

    /// 완료 신호가 있는 케이스에서 어댑터가 실제로 완료를 감지하는지 검증.
    func testCompletionDetection_consistency() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases {
                guard !testCase.completionSignal.isEmpty else { continue }
                guard let adapter = createAdapter(type: testCase.adapterType) else { continue }

                let isComplete = adapter.isResponseComplete(screenBuffer: testCase.screenText)

                if testCase.completionSignal == "ready_signal" && !isComplete {
                    XCTFail("""
                    [\(url.lastPathComponent)] \(testCase.id): 완료 감지 실패
                    신호: \(testCase.completionSignal)
                    isResponseComplete()가 false를 반환
                    """)
                }
            }
        }
    }

    // MARK: - Helpers

    private func loadFixture(url: URL) throws -> FixtureFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureFile.self, from: data)
    }

    private func preview(_ text: String) -> String {
        let oneline = text.replacingOccurrences(of: "\n", with: "\\n")
        if oneline.count <= 80 { return "\"\(oneline)\"" }
        return "\"\(oneline.prefix(77))...\""
    }

    private func stringSimilarity(_ a: String, _ b: String) -> Double {
        let maxLen = max(a.count, b.count)
        guard maxLen > 0 else { return 1.0 }

        var common = 0
        let aChars = Array(a)
        let bChars = Array(b)
        for i in 0..<min(aChars.count, bChars.count) {
            if aChars[i] == bChars[i] { common += 1 } else { break }
        }
        return Double(common) / Double(maxLen)
    }

    /// 텍스트에서 중복된 줄을 찾는다.
    private func findDuplicatedLines(_ text: String, minLength: Int) -> [String] {
        let lines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minLength }

        var seen = Set<String>()
        var duplicates: [String] = []
        for line in lines {
            if seen.contains(line) {
                if !duplicates.contains(line) {
                    duplicates.append(line)
                }
            } else {
                seen.insert(line)
            }
        }
        return duplicates
    }
}
