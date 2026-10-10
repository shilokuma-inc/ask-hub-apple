import Foundation

/// 実機確認 Issue の本文先頭に置く目印。
///
/// ```html
/// <!-- ask-hub:verify {"pullRequest":123,"epic":"epic/xxx"} -->
/// ```
///
/// 詳細は `docs/protocol.md` の「実機確認 Issue の目印」を参照。
/// キーはどちらも任意（オーケストレーターの App Store Connect の Issue には元の PR が無いなど）。
/// **信用する author が作った Issue の目印だけを読む**（`TrustedAuthors` を使う）。
public struct VerifyMarker: Sendable, Equatable, Codable {
    /// 実機確認のきっかけになった元の PR 番号（任意）
    public var pullRequest: Int?
    /// 統合ブランチ（例: `epic/xxx`）（任意）
    public var epic: String?

    public init(pullRequest: Int? = nil, epic: String? = nil) {
        self.pullRequest = pullRequest
        self.epic = epic
    }

    // MARK: - 目印の生成・パース

    private static let commentOpen = "<!--"
    private static let commentClose = "-->"
    private static let keyword = "ask-hub:verify"

    /// Issue 本文の先頭に置く HTML コメント
    public var marker: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        let json = encoded.replacingOccurrences(of: ">", with: "\\u003e")
        return "\(Self.commentOpen) \(Self.keyword) \(json) \(Self.commentClose)"
    }

    /// Issue 本文から目印を読み取る。
    ///
    /// 目印は本文の先頭（前後の空白・改行は無視する）にある場合だけ認める。
    /// 形式が崩れている場合は `nil` を返す。
    /// author が信用できるかはここでは判定しない（`TrustedAuthors` を使う）。
    public static func parse(_ body: String) -> Self? {
        let trimmed = body.drop { $0.isWhitespace || $0.isNewline }
        guard trimmed.hasPrefix(commentOpen),
              let closeRange = trimmed.range(of: commentClose) else {
            return nil
        }
        let inner = trimmed[trimmed.index(trimmed.startIndex, offsetBy: commentOpen.count)..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inner.hasPrefix(keyword) else {
            return nil
        }
        let rest = inner.dropFirst(keyword.count)
        // `ask-hub:verifier` のような別の語を誤って拾わないよう、直後は空白か終端に限る
        guard rest.isEmpty || rest.first?.isWhitespace == true else {
            return nil
        }
        let decoder = JSONDecoder()
        return try? decoder.decode(Self.self, from: Data(rest.utf8))
    }
}
