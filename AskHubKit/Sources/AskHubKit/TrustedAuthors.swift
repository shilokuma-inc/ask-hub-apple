/// 質問・回答・依頼を出してよい GitHub アカウントの一覧。
///
/// public リポジトリでは誰でもコメントできるため、GitHub 上のテキストは
/// ここに含まれる author のものだけを扱う。詳細は `docs/protocol.md` の「信用する author」を参照。
public struct TrustedAuthors: Sendable, Equatable {
    /// 設定が無いときの既定の login
    public static let defaultLogins = ["mrs1669"]
    /// 設定が無いときの既定値
    public static let `default` = Self(defaultLogins)

    /// 小文字に揃えた login。GitHub の login は大文字・小文字を区別しない
    private let logins: Set<String>

    public init(_ logins: some Sequence<String>) {
        self.logins = Set(logins.map { $0.lowercased() })
    }

    /// 信用する author か。削除済みのユーザー（author が `nil`）は信用しない
    public func contains(_ login: String?) -> Bool {
        guard let login else {
            return false
        }
        return logins.contains(login.lowercased())
    }

    /// コメントが質問なら、その目印を返す。信用する author 以外が書いた目印は無視する
    public func question(in body: String, author: String?) -> QuestionMarker? {
        guard contains(author) else {
            return nil
        }
        return QuestionMarker.parse(body)
    }

    /// 質問コメントへの返信の author から、回答済みかを判定する。
    /// 信用する author の返信が 1 件以上あれば回答済み
    public func isAnswered(replyAuthors: some Sequence<String?>) -> Bool {
        replyAuthors.contains { contains($0) }
    }
}
