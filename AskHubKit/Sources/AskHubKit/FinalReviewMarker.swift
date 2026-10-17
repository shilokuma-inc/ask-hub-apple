import Foundation

/// 最終 PR（`epic-final`）の第三者レビューの進み具合。オーケストレーターが最終 PR に置く状態コメント 1 件の本文の先頭に置き、
/// 状態が変わったら同じコメントを書き換える。
///
/// ```html
/// <!-- ask-hub:final-review state="reviewing" sha="<今の head>" attempts="1" -->
/// ```
///
/// 詳細は `docs/protocol.md` の「最終 PR の第三者レビューの進み具合」を参照。
public struct FinalReviewMarker: Sendable, Equatable, Hashable {
    /// 第三者レビューの進み具合
    public enum State: String, Sendable, Equatable, Hashable, CaseIterable {
        /// CodeRabbit のレビューを待っている（head が変わってから 10 分）
        case waiting
        /// 第三者レビュー中
        case reviewing
        /// 要修正を直している
        case fixing
        /// 済み（今の head の第三者レビューで要修正が 0 件）
        case done
        /// 済み（CodeRabbit が今の head をレビューした）
        case doneCodeRabbit = "done-coderabbit"
        /// あきらめた（要修正が 3 回続けて収まらなかった。人が直して push すればやり直す）
        case gaveUp = "gave-up"
    }

    public var state: State
    /// この状態を判断した head のコミットの SHA（40 文字の小文字の 16 進。`init` で小文字にそろえる）
    public var sha: String
    /// 今の追跡で要修正が続いた回数
    public var attempts: Int

    public init(state: State, sha: String, attempts: Int = 0) {
        self.state = state
        self.sha = sha.lowercased()
        self.attempts = attempts
    }

    /// 進み具合の説明（アプリの詳細画面と、オーケストレーターの状態コメントで使う）
    public var progressText: String {
        switch state {
        case .waiting:
            "CodeRabbit を待っています"

        case .reviewing:
            "レビュー中"

        case .fixing:
            attempts > 0 ? "修正中（\(attempts) 回目）" : "修正中"

        case .done:
            "済み"

        case .doneCodeRabbit:
            "済み（CodeRabbit）"

        case .gaveUp:
            attempts > 0 ? "あきらめました（要修正が \(attempts) 回続きました）" : "あきらめました"
        }
    }

    /// コメント本文の先頭に置く HTML コメント。`sha` が目印で表せない値なら `nil`
    public var htmlComment: String? {
        guard ThirdPartyReviewMarker.isValidSHA(sha), attempts >= 0 else {
            return nil
        }
        return #"<!-- \#(Self.keyword) state="\#(state.rawValue)" sha="\#(sha)" attempts="\#(attempts)" -->"#
    }

    /// コメント本文から目印を読み取る。
    ///
    /// 目印は本文の先頭（前後の空白・改行は無視する）にある場合だけ認める。
    /// 知らない `state`・40 文字の 16 進でない `sha`・0 以上の整数でない `attempts` は `nil`。`attempts` が無ければ 0 とみなす。
    /// author が信用できるか・`sha` が今の head かはここでは判定しない
    public static func parse(_ body: String) -> Self? {
        guard let attributes = MarkerComment.attributes(body, keyword: keyword),
              let state = attributes["state"].flatMap(State.init(rawValue:)),
              let sha = attributes["sha"], ThirdPartyReviewMarker.isValidSHA(sha) else {
            return nil
        }
        let attempts: Int
        if let value = attributes["attempts"] {
            guard let parsed = ThirdPartyReviewMarker.count(value) else {
                return nil
            }
            attempts = parsed
        } else {
            attempts = 0
        }
        return Self(state: state, sha: sha, attempts: attempts)
    }

    static let keyword = "ask-hub:final-review"
}
