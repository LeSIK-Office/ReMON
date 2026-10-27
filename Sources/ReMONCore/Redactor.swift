import Foundation

/// 현황판·카드에 보이는 작업 제목에서 비밀값·개인정보를 가린다(사양 2-2).
public enum Redactor {
    private static let patterns: [NSRegularExpression] = [
        #"sk-[A-Za-z0-9_\-]{16,}"#,
        #"(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}"#,
        #"github_pat_[A-Za-z0-9_]{20,}"#,
        #"AKIA[0-9A-Z]{16}"#,
        #"xox[abprs]-[A-Za-z0-9\-]{10,}"#,
        #"eyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        #"(?i)(password|passwd|secret|token|api[_-]?key)\s*[:=]\s*\S+"#,
        #"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}"#,
        #"01[016789][\- ]?\d{3,4}[\- ]?\d{4}"#,
        #"\b[0-9a-fA-F]{32,}\b"#,
        // 긴 토큰: 숫자와 글자가 섞인 40자 이상. 경로(/로 끊김)·일반 단어는 가리지 않는다.
        #"\b(?=[A-Za-z0-9+_\-]*\d)(?=[A-Za-z0-9+_\-]*[A-Za-z])[A-Za-z0-9+_\-]{40,}={0,2}"#
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            let range = NSRange(result.startIndex..., in: result)
            result = pattern.stringByReplacingMatches(in: result, range: range, withTemplate: "••••")
        }
        return result
    }

    /// 첫 줄만, 최대 길이로 자르고 가린다.
    public static func headline(_ text: String, limit: Int = 64) -> String? {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty else { return nil }
        let redacted = redact(line)
        return redacted.count > limit ? String(redacted.prefix(limit - 1)) + "…" : redacted
    }
}
