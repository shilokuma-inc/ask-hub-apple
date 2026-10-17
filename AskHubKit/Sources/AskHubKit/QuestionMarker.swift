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
        MarkerComment.isValidValue(id) && options.allSatisfy { option in
            MarkerComment.isValidValue(option)
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
        guard let attributes = MarkerComment.attributes(body, keyword: keyword),
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
}
