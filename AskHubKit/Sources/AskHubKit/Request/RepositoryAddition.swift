import Foundation

/// 担当 PC に入れる、GitHub にある既存のリポジトリ（`repo-request` の `add`）。
///
/// 依頼 Issue は、入れる先の PC の担当リポジトリに作る。そのオーケストレーターが決まった場所
/// （`newRepositoryDirectory/<リポジトリ名>`）に clone し（同じ origin の checkout が既にあればそれを使う）、
/// AskHub のラベル・Discussions・ralph-kit の中継を用意して、担当リポジトリに加える。
/// 置き場所も準備も決まっているので、選ぶものはリポジトリだけ
public struct RepositoryAddition: Sendable, Equatable {
    /// `owner/repo`
    public var repository: String

    public init(repository: String) {
        self.repository = repository
    }

    /// 送ってよい形か
    public var isValid: Bool {
        RepositoryName.isValidFullName(repository)
    }

    /// Issue の本文の、人が読む説明
    var issueDescription: String {
        """
        ## 担当リポジトリに加える

        | 項目 | 値 |
        | --- | --- |
        | リポジトリ | \(repository) |
        | 担当 PC への clone | 担当 PC の決まった場所に clone する（同じ origin の checkout が既にあればそれを使う） |
        | 準備 | AskHub のラベル・Discussions・ralph-kit の中継（無ければ develop に直接 push） |

        GitHub のリポジトリの設定（公開範囲など）は変えません。
        """
    }
}
