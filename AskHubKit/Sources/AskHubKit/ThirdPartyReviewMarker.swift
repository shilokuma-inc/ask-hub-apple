import Foundation

/// 第三者レビューのコメント本文の先頭に置く目印（ralph-kit#17 の書式）。
///
/// ```html
/// <!-- ralph:third-party-review sha="<レビューした head>" must="1" may="2" -->
/// ```
///
/// `must` は `🔴 要修正`、`may` は `🟡 提案` の件数。最終 PR では、今の head の目印で `must="0"` ならマージできる。
/// 詳細は `docs/protocol.md` の「第三者レビューの目印」を参照。
public struct ThirdPartyReviewMarker: Sendable, Equatable, Hashable {
    /// レビューした head のコミットの SHA（小文字の 16 進）
    public var sha: String
    /// `🔴 要修正` の件数
    public var must: Int
    /// `🟡 提案` の件数
    public var may: Int

    public init(sha: String, must: Int, may: Int) {
        self.sha = sha
        self.must = must
        self.may = may
    }

    /// 要修正が無い（このレビューではマージを止めない）か
    public var isClean: Bool {
        must == 0
    }

    /// コメント本文の先頭に置く HTML コメント。`sha` が目印で表せない値なら `nil`
    public var htmlComment: String? {
        guard Self.isValidSHA(sha), must >= 0, may >= 0 else {
            return nil
        }
        return #"<!-- \#(Self.keyword) sha="\#(sha)" must="\#(must)" may="\#(may)" -->"#
    }

    /// コメント本文から目印を読み取る。
    ///
    /// 目印は本文の先頭（前後の空白・改行は無視する）にある場合だけ認める。
    /// `sha` が 16 進でない・`must` が無い（以前の書式）・件数が 0 以上の整数でない場合は `nil`。`may` が無ければ 0 とみなす。
    /// author が信用できるか・`sha` が今の head かはここでは判定しない
    public static func parse(_ body: String) -> Self? {
        guard let attributes = MarkerComment.attributes(body, keyword: keyword),
              let sha = attributes["sha"], isValidSHA(sha),
              let must = attributes["must"].flatMap(count) else {
            return nil
        }
        let may: Int
        if let value = attributes["may"] {
            guard let parsed = count(value) else {
                return nil
            }
            may = parsed
        } else {
            may = 0
        }
        return Self(sha: sha.lowercased(), must: must, may: may)
    }

    static let keyword = "ralph:third-party-review"

    /// 7〜40 文字の 16 進（大文字小文字は問わない）
    static func isValidSHA(_ value: String) -> Bool {
        (7...40).contains(value.count) && value.allSatisfy(\.isHexDigit)
    }

    /// 0 以上の整数（`+` や空白は認めない）
    static func count(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) else {
            return nil
        }
        return Int(value)
    }
}
