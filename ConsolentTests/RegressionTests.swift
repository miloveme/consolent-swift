import XCTest
@testable import Consolent

// MARK: - Fixture 모델

/// 로그에서 추출한 회귀 테스트 fixture 파일 형식.
/// `tools/extract_fixtures.py`가 생성하고, 이 테스트가 로드한다.
private struct FixtureFile: Decodable {
    let metadata: Metadata
    let cases: [FixtureCase]

    struct Metadata: Decodable {
        let source: String
        let sessionId: String
        let cliType: String
        let description: String
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

        // 스트리밍 전용 (옵션)
        let baseline: String?
        let pollCount: Int?
        let totalDeltaLength: Int?
        let streamingDeltas: [String]?
    }
}

// MARK: - RegressionTests

/// 로그 기반 회귀 테스트.
/// `ConsolentTests/Fixtures/fixture_*.json` 파일을 로드하여
/// `adapter.cleanResponse(screenText)` 결과가 기대값과 일치하는지 검증한다.
///
/// 새 fixture 추가 방법:
/// 1. 문제 발생 시 로그 파일 확보 (`~/Library/Logs/Consolent/debug/`)
/// 2. `python3 tools/extract_fixtures.py <log.jsonl>` 실행
/// 3. 생성된 `ConsolentTests/Fixtures/fixture_*.json`에 description 기재
/// 4. 테스트 실행 → 실패하면 어댑터 수정 → 테스트 통과 확인
final class RegressionTests: XCTestCase {

    /// Fixtures 디렉토리 내 모든 fixture 파일 경로
    private static var fixtureURLs: [URL] = {
        // 번들에서 Fixtures 디렉토리 검색
        let bundle = Bundle(for: RegressionTests.self)
        guard let resourceURL = bundle.resourceURL else { return [] }

        // XCTest 번들의 리소스에서 fixture 파일 검색
        let fixturesDir = resourceURL.appendingPathComponent("Fixtures")
        if let files = try? FileManager.default.contentsOfDirectory(
            at: fixturesDir,
            includingPropertiesForKeys: nil
        ) {
            return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("fixture_") }
        }

        // 번들에 Fixtures 폴더가 없으면 소스 디렉토리에서 직접 검색 (개발 환경)
        return findFixturesInSourceDir()
    }()

    /// 소스 디렉토리에서 fixture 파일 검색 (번들 리소스에 없을 때 폴백)
    private static func findFixturesInSourceDir() -> [URL] {
        // 프로젝트 루트를 추정 — 빌드 디렉토리에서 역추적
        let fm = FileManager.default

        // 환경변수에서 프로젝트 루트 확인
        if let srcRoot = ProcessInfo.processInfo.environment["SRCROOT"] {
            let fixturesDir = URL(fileURLWithPath: srcRoot)
                .appendingPathComponent("ConsolentTests/Fixtures")
            if let files = try? fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil) {
                return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("fixture_") }
            }
        }

        // __FILE__ 기반 추정
        let thisFile = URL(fileURLWithPath: #file)
        let fixturesDir = thisFile.deletingLastPathComponent().appendingPathComponent("Fixtures")
        if let files = try? fm.contentsOfDirectory(at: fixturesDir, includingPropertiesForKeys: nil) {
            return files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("fixture_") }
        }

        return []
    }

    /// 어댑터 타입 문자열에서 CLIAdapter 인스턴스 생성
    private func createAdapter(type: String) -> CLIAdapter? {
        switch type {
        case "ClaudeCodeAdapter": return ClaudeCodeAdapter()
        case "GeminiAdapter":    return GeminiAdapter()
        case "CodexAdapter":     return CodexAdapter()
        default:                 return nil
        }
    }

    // MARK: - cleanResponse 회귀 테스트

    /// 모든 fixture 파일의 모든 케이스에서 cleanResponse가 기대값과 일치하는지 검증.
    func testCleanResponse_allFixtures() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else {
            // fixture가 없으면 테스트 건너뜀 (CI 환경 등)
            print("[RegressionTests] fixture 파일 없음 — 건너뜀")
            return
        }

        var totalCases = 0
        var passedCases = 0
        var failures: [(file: String, caseId: String, message: String)] = []

        for url in urls {
            let fixture = try loadFixture(url: url)
            let desc = fixture.metadata.description.isEmpty
                ? fixture.metadata.source
                : fixture.metadata.description

            for testCase in fixture.cases {
                totalCases += 1

                guard let adapter = createAdapter(type: testCase.adapterType) else {
                    failures.append((
                        file: url.lastPathComponent,
                        caseId: testCase.id,
                        message: "알 수 없는 어댑터: \(testCase.adapterType)"
                    ))
                    continue
                }

                let actual = adapter.cleanResponse(testCase.screenText)

                if actual == testCase.expectedCleanText {
                    passedCases += 1
                } else {
                    failures.append((
                        file: url.lastPathComponent,
                        caseId: testCase.id,
                        message: """
                        [\(desc)] cleanResponse 불일치
                        어댑터: \(testCase.adapterType)
                        메시지: "\(testCase.message)"
                        기대 (\(testCase.expectedCleanText.count)자): \(preview(testCase.expectedCleanText))
                        실제 (\(actual.count)자): \(preview(actual))
                        """
                    ))
                }
            }
        }

        print("[RegressionTests] cleanResponse: \(passedCases)/\(totalCases) 통과")

        if !failures.isEmpty {
            let report = failures.map { "[\($0.file)] \($0.caseId):\n\($0.message)" }
                .joined(separator: "\n\n")
            XCTFail("cleanResponse 회귀 실패 \(failures.count)건:\n\n\(report)")
        }
    }

    // MARK: - 빈 응답 감지 테스트

    /// wasEmpty가 true인 케이스에서 실제로 cleanResponse가 빈 문자열인지 확인.
    /// 어댑터를 수정하여 빈 응답이 해결되면 fixture의 expectedCleanText와 wasEmpty를 업데이트.
    func testEmptyResponse_detection() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        var detectedEmpty = 0

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases where testCase.wasEmpty {
                guard let adapter = createAdapter(type: testCase.adapterType) else { continue }

                let actual = adapter.cleanResponse(testCase.screenText)
                if actual.isEmpty {
                    detectedEmpty += 1
                } else {
                    // 빈 응답이었는데 이제 파싱되면 = 어댑터 개선됨!
                    // fixture를 업데이트해야 함을 알림
                    print("[RegressionTests] 🎉 이전 빈 응답이 이제 파싱됨: \(testCase.id)")
                    print("  파싱 결과: \(preview(actual))")
                    print("  → fixture의 expectedCleanText와 wasEmpty를 업데이트하세요")
                }
            }
        }

        if detectedEmpty > 0 {
            print("[RegressionTests] ⚠️ 여전히 빈 응답: \(detectedEmpty)건 — 어댑터 개선 필요")
        }
    }

    // MARK: - 스트리밍 델타 연속성 테스트

    /// 스트리밍 케이스에서 델타를 이어붙인 결과가 최종 응답의 부분 문자열인지 검증.
    func testStreamingDeltas_consistency() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases where testCase.type == "streaming" {
                guard let deltas = testCase.streamingDeltas, !deltas.isEmpty else { continue }

                // 플레이스홀더("... omitted ...") 필터
                let realDeltas = deltas.filter { !$0.hasPrefix("...") }
                let accumulated = realDeltas.joined()

                // 누적 델타가 최종 응답의 부분인지 확인
                // (스트리밍 노이즈 필터링 때문에 정확히 같지 않을 수 있음)
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

                // screenText로 완료 감지 확인
                let isComplete = adapter.isResponseComplete(screenBuffer: testCase.screenText)

                if testCase.completionSignal == "ready_signal" && !isComplete {
                    // ready_signal로 완료됐는데 isResponseComplete가 false면 문제
                    XCTFail("""
                    [\(url.lastPathComponent)] \(testCase.id): 완료 감지 실패
                    신호: \(testCase.completionSignal)
                    isResponseComplete()가 false를 반환
                    """)
                }
            }
        }
    }

    // MARK: - 의심 케이스 리포트

    /// suspicious로 표시된 케이스를 리포트한다.
    /// 테스트 자체는 실패시키지 않지만 (어댑터 수정 전까지는 기존 동작),
    /// 어댑터 수정 후 suspicious 사유가 해소되면 fixture를 업데이트하라고 알린다.
    func testSuspicious_report() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        var suspiciousCases: [(file: String, id: String, reasons: [String])] = []

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases {
                guard testCase.suspicious == true,
                      let reasons = testCase.suspiciousReasons, !reasons.isEmpty else { continue }

                suspiciousCases.append((
                    file: url.lastPathComponent,
                    id: testCase.id,
                    reasons: reasons
                ))
            }
        }

        if !suspiciousCases.isEmpty {
            let report = suspiciousCases.map { c in
                "[\(c.file)] \(c.id): \(c.reasons.joined(separator: ", "))"
            }.joined(separator: "\n  ")
            print("[RegressionTests] 🔍 의심 케이스 \(suspiciousCases.count)건:\n  \(report)")
        }
    }

    // MARK: - TUI 노이즈 감지 테스트

    /// cleanResponse 결과에 TUI 노이즈가 남아있는지 검증.
    /// suspicious fixture에서 tui_noise 사유가 있는 케이스를 직접 테스트.
    func testTUINoiseInCleanResponse() throws {
        let urls = Self.fixtureURLs
        guard !urls.isEmpty else { return }

        let noisePatterns = [
            "esc to interrupt", "esc to cancel",
            "? for shortcuts", "shift+tab to cycle",
        ]

        var noiseFound = 0

        for url in urls {
            let fixture = try loadFixture(url: url)

            for testCase in fixture.cases {
                guard let adapter = createAdapter(type: testCase.adapterType) else { continue }

                let actual = adapter.cleanResponse(testCase.screenText)
                let lower = actual.lowercased()

                for pattern in noisePatterns {
                    if lower.contains(pattern) {
                        noiseFound += 1
                        print("[RegressionTests] 🔍 TUI 노이즈 발견: \(testCase.id) — \"\(pattern)\"")
                        break
                    }
                }
            }
        }

        if noiseFound > 0 {
            print("[RegressionTests] ⚠️ TUI 노이즈가 남은 응답: \(noiseFound)건 — 어댑터 필터 개선 필요")
        }
    }

    // MARK: - Helpers

    private func loadFixture(url: URL) throws -> FixtureFile {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(FixtureFile.self, from: data)
    }

    /// 문자열 미리보기 (최대 80자)
    private func preview(_ text: String) -> String {
        let oneline = text.replacingOccurrences(of: "\n", with: "\\n")
        if oneline.count <= 80 { return "\"\(oneline)\"" }
        return "\"\(oneline.prefix(77))...\""
    }

    /// 간단한 문자열 유사도 (공통 접두사 길이 / 최대 길이)
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
}
