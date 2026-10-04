import Foundation

/// 質問のコメント本文の先頭に置く目印。
///
/// ```html
/// <!-- ask-hub:question id="d12-q3" options="24時間|1時間|送信1回分" -->
/// ```
///
/// 詳細は `docs/protocol.md` の「質問の目印」を参照。
public struct QuestionMarker: Sendable, Equatable, Hashable {
    /// リポジトリ内で一意な質問の id
    public var id: String
    /// 選択肢。空なら自由記述のみの質問
    public var options: [String]

    public init(id: String, options: [String] = []) {
        self.id = id
        self.options = options
    }

    /// 選択肢の無い（自由記述のみの）質問か
    public var isFreeForm: Bool {
        options.isEmpty
    }

    /// コメント本文の先頭に置く HTML コメント。
    ///
    /// 目印はエスケープの規則を持たない（Claude が手で書く形式のため）。
    /// `id` や選択肢が目印で表せない値を含む場合は、読み戻すと別の質問になるので `nil` を返す。
    public var htmlComment: String? {
        guard isRepresentable else {
            return nil
        }
        var attributes = #"id="\#(id)""#
        if !options.isEmpty {
            attributes += #" options="\#(options.joined(separator: Self.optionSeparator))""#
        }
        return "<!-- \(Self.keyword) \(attributes) -->"
    }

    /// `htmlComment` で表せるか。
    ///
    /// `id` と選択肢は空でなく、`"`・改行・`-->` を含まないこと。選択肢は `|` を含まず、前後に空白を持たないこと
    public var isRepresentable: Bool {
        func isValidValue(_ value: String) -> Bool {
            !value.isEmpty && !value.contains("\"") && !value.contains(where: \.isNewline) && !value.contains(Self.commentClose)
        }
        return isValidValue(id) && options.allSatisfy { option in
            isValidValue(option)
                && !option.contains(Self.optionSeparator)
                && option == option.trimmingCharacters(in: .whitespaces)
        }
    }

    /// コメント本文から目印を読み取る。
    ///
    /// 目印は本文の先頭（前後の空白・改行は無視する）にある場合だけ認める。
    /// `id` が無い・空の場合や、形式が崩れている場合は `nil` を返す。
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
        // `ask-hub:questionnaire` のような別の語を誤って拾わないよう、直後は空白か終端に限る
        if let next = rest.first, !next.isWhitespace {
            return nil
        }
        guard let attributes = parseAttributes(rest),
              let id = attributes["id"], !id.isEmpty else {
            return nil
        }
        let options = (attributes["options"] ?? "")
            .split(separator: optionSeparator)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Self(id: id, options: options)
    }

    static let keyword = "ask-hub:question"
    static let optionSeparator = "|"
    private static let commentOpen = "<!--"
    static let commentClose = "-->"

    /// `name="value"` の並びを読み取る。並びとして崩れていれば `nil`。同じ名前は最初のものを採用する
    private static func parseAttributes(_ text: Substring) -> [String: String]? {
        var attributes: [String: String] = [:]
        var rest = text[...]
        while true {
            rest = rest.drop { $0.isWhitespace }
            if rest.isEmpty {
                return attributes
            }
            guard let match = rest.prefixMatch(of: /([A-Za-z][A-Za-z0-9_-]*)="([^"]*)"/) else {
                return nil
            }
            let name = String(match.output.1)
            if attributes[name] == nil {
                attributes[name] = String(match.output.2)
            }
            rest = rest[match.range.upperBound...]
        }
    }
}
