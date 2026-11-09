import Foundation

/// コマンドの出力やログの抜粋から、トークンらしい文字列を伏せる（`docs/renewal/architecture.md` の「ジョブと試行」）
public enum Redaction {
    /// 抜粋の長さの上限（文字数。末尾を残す）
    public static let maximumExcerpt = 2000

    /// 伏せてから前後の空白を除き、末尾の `maximumExcerpt` 文字を返す。空になれば nil
    public static func excerpt(of text: String, secrets: [String]) -> String? {
        let redacted = redact(text, secrets: secrets).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !redacted.isEmpty else { return nil }
        return String(redacted.suffix(maximumExcerpt))
    }

    /// `secrets`（8 文字以上のもの）と、トークンらしい文字列を `<伏せた>` に置き換える
    public static func redact(_ text: String, secrets: [String]) -> String {
        var text = text
        for secret in secrets where secret.count >= 8 {
            text = text.replacingOccurrences(of: secret, with: "<伏せた>")
        }
        for pattern in patterns {
            text = text.replacing(pattern) { _ in "<伏せた>" }
        }
        return text
    }

    /// Anthropic の API キーと setup-token、GitHub のトークン、Authorization の値。
    /// `Regex` は Sendable ではないので、共有の定数にせず、呼ぶたびに作る
    private static var patterns: [Regex<Substring>] {
        [
            #/sk-ant-[A-Za-z0-9_\-]{8,}/#,
            #/gh[pousr]_[A-Za-z0-9]{20,}/#,
            #/github_pat_[A-Za-z0-9_]{20,}/#,
            #/(?i)bearer\s+[A-Za-z0-9._\-]{8,}/#
        ]
    }
}
