import Foundation

/// コメント本文の先頭に置く `<!-- <keyword> name="value" … -->` 形式の目印を読む共通の処理。
/// `QuestionMarker`・`ThirdPartyReviewMarker`・`FinalReviewMarker` が使う
enum MarkerComment {
    static let open = "<!--"
    static let close = "-->"

    /// 本文の先頭（前後の空白・改行は無視する）にある HTML コメントの中身（`<!--` と `-->` の間。前後の空白・改行を除く）を返す。
    /// 先頭がコメントでない・閉じていなければ `nil`。
    /// `VerifyMarker`・`LoopStatusReport` などの JSON の目印も、これで中身を取り出す
    static func leadingCommentContent(_ body: String) -> String? {
        let trimmed = body.drop { $0.isWhitespace || $0.isNewline }
        guard trimmed.hasPrefix(open) else {
            return nil
        }
        // 閉じは開きの後ろから探す。本文の先頭から探すと、`<!-->` などで開きと重なる `-->` に当たり、範囲を作れずに落ちる
        let afterOpen = trimmed.dropFirst(open.count)
        guard let closeRange = afterOpen.range(of: close) else {
            return nil
        }
        return afterOpen[..<closeRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 本文の先頭（前後の空白・改行は無視する）にある `keyword` の目印の属性を返す。
    ///
    /// 目印が先頭に無い・別の語（`keyword` の後ろに文字が続くもの）・属性の並びが崩れている場合は `nil`。
    /// 同じ名前の属性は最初のものを採用する
    static func attributes(_ body: String, keyword: String) -> [String: String]? {
        guard let inner = leadingCommentContent(body), inner.hasPrefix(keyword) else {
            return nil
        }
        let rest = inner.dropFirst(keyword.count)
        // `ask-hub:questionnaire` のような別の語を誤って拾わないよう、直後は空白か終端に限る
        if let next = rest.first, !next.isWhitespace {
            return nil
        }
        return parseAttributes(rest)
    }

    /// 属性の値として目印に書けるか（空でなく、`"`・改行・`-->` を含まない）
    static func isValidValue(_ value: String) -> Bool {
        !value.isEmpty && !value.contains("\"") && !value.contains(where: \.isNewline) && !value.contains(close)
    }

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
