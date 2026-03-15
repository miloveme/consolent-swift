import Foundation

/// CJK wide character 패딩 공백 처리 유틸리티.
/// SwiftTerm은 wide char(2열) 뒤에 패딩 공백을 삽입하는데, 이를 감지·제거한다.
/// ClaudeCodeAdapter, GeminiAdapter 등 여러 어댑터에서 공유한다.
enum CJKSpacingFix {

    /// 여러 줄의 텍스트에서 CJK 패딩 공백을 제거한다.
    static func fixCJKSpacing(_ text: String) -> String {
        return text.components(separatedBy: "\n")
            .map { fixCJKSpacingInLine($0) }
            .joined(separator: "\n")
    }

    /// 한 줄에서 CJK 패딩 공백을 제거한다.
    ///
    /// 패딩 감지: CJK 문자의 50% 이상이 뒤에 공백이 있으면 패딩으로 판단.
    /// - 1칸 공백 (패딩만) → 제거
    /// - 2칸 공백 (패딩 + 단어 경계) → 1칸 공백 보존
    /// - 정상 한국어 텍스트(패딩 없음)는 건드리지 않는다.
    private static func fixCJKSpacingInLine(_ line: String) -> String {
        let chars = Array(line)
        guard chars.count >= 3 else { return line }

        // 패딩 감지: CJK 문자 뒤에 공백이 있는 비율
        var cjkCount = 0
        var paddedCount = 0
        for i in 0..<chars.count {
            if isCJK(chars[i]) {
                cjkCount += 1
                if i + 1 < chars.count && chars[i + 1] == " " {
                    paddedCount += 1
                }
            }
        }

        // CJK가 2개 미만이거나 패딩 비율 50% 이하면 정상 텍스트 → 그대로 반환
        guard cjkCount >= 2, Double(paddedCount) / Double(cjkCount) > 0.5 else {
            return line
        }

        // CJK 문자 뒤의 패딩 공백 제거
        var result: [Character] = []
        var i = 0

        while i < chars.count {
            result.append(chars[i])

            if isCJK(chars[i]) && i + 1 < chars.count && chars[i + 1] == " " {
                if i + 2 < chars.count && chars[i + 2] == " " {
                    // 2칸 공백 (패딩 + 단어 경계) → 1칸 공백 보존
                    result.append(" ")
                    i += 3
                } else {
                    // 1칸 공백 (패딩만) → 제거
                    i += 2
                }
            } else {
                i += 1
            }
        }

        return String(result)
    }

    /// CJK 문자인지 판별한다.
    /// Hangul, CJK Ideographs, Hiragana, Katakana, Fullwidth Forms 등 포함.
    static func isCJK(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        let v = scalar.value
        return (0x1100...0x11FF).contains(v) ||   // Hangul Jamo
               (0x2E80...0x9FFF).contains(v) ||   // CJK Radicals ~ CJK Unified Ideographs
               (0xAC00...0xD7AF).contains(v) ||   // Hangul Syllables
               (0xF900...0xFAFF).contains(v) ||   // CJK Compatibility Ideographs
               (0xFE30...0xFE4F).contains(v) ||   // CJK Compatibility Forms
               (0x3000...0x30FF).contains(v) ||   // CJK Symbols, Hiragana, Katakana
               (0x31F0...0x31FF).contains(v) ||   // Katakana Extensions
               (0xFF00...0xFFEF).contains(v)      // Fullwidth Forms
    }
}
