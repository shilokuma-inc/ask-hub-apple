import AskHubProtocol
import Foundation

/// Claude に読ませる、対象のリポジトリの作業場所
public struct PreparedWorkspace: Sendable {
    /// 対象のリポジトリの base（無ければ既定のブランチ）の写し（読むだけ）
    public var directory: URL
    /// リポジトリの事実（CLAUDE.md の全員向けの事実）。`--restricted` では CLAUDE.md が読まれないので、決まりの文に入れて渡す
    public var facts: String

    public init(directory: URL, facts: String) {
        self.directory = directory
        self.facts = facts
    }
}

/// 対象のリポジトリの写しを用意する（常時オンの Mac のワーカー専用のフォルダに partial clone で作り、使うたびに最新にする）
public protocol RepositoryWorkspace: Sendable {
    /// ジョブ用の写し（`base` の最新。nil なら既定のブランチの最新）を用意する。並んで動くほかのジョブの写しとは分ける
    func prepare(_ repo: RepositoryFullName, base: String?, for job: ULID) async throws(WorkspaceError) -> PreparedWorkspace

    /// 依頼の添付を置く、Claude が読んでよいフォルダ（ジョブごとに作る）
    func attachmentsDirectory(for job: ULID) async throws(WorkspaceError) -> URL

    /// ジョブの写しと添付のフォルダを片付ける（ジョブを終えたときに呼ぶ。片付けられなくても止めない）
    func release(_ job: ULID) async

    /// しばらく使っていない写しを片付ける（司令塔が定期的に呼ぶ）
    func tidy() async
}

extension RepositoryWorkspace {
    public func tidy() async {}
}

/// epic の作業場所（作業ブランチを取り出した worktree）
public struct PreparedEpicWorkspace: Equatable, Sendable {
    /// 作業ブランチを取り出したフォルダ。ジョブを超えて残し、最終 PR のマージ後に消す
    public var directory: URL
    /// 作業ブランチ（`askhub/<epic の id>`）
    public var branch: String
    /// 作業ブランチの先頭のコミット
    public var head: String

    public init(directory: URL, branch: String, head: String) {
        self.directory = directory
        self.branch = branch
        self.head = head
    }
}

/// epic の作業場所を用意する（`docs/renewal/flows.md` の「作業ブランチと子 PR」）
public protocol EpicWorkspace: Sendable {
    /// 作業ブランチを取り出した、epic の作業場所を用意する。作業ブランチがリモートに無ければ `origin/<base>` から作って push する。
    /// リモートにあれば作り直さずに使う（やり直しで二重に作らない・force push しない）
    func prepareEpic(
        _ repo: RepositoryFullName,
        epic: ULID,
        branch: String,
        base: String
    ) async throws(WorkspaceError) -> PreparedEpicWorkspace
}

public enum WorkspaceError: Error, Equatable, Sendable {
    /// GitHub に届かない・混み合っている（待ってやり直す）
    case unavailable(String)
    /// 認証が切れている・権限が無い
    case unauthorized(String)
    case failed(String)

    /// 試行の失敗として書く形
    var attemptFailure: AttemptFailure {
        switch self {
        case let .unavailable(detail): AttemptFailure(failureClass: .githubOutage, message: "リポジトリの写しを用意できない（\(detail)）")
        case let .unauthorized(detail): AttemptFailure(failureClass: .authExpired, message: "リポジトリを読む権限が無い（\(detail)）")
        case let .failed(detail): AttemptFailure(failureClass: .unexpected, message: "リポジトリの写しを用意できない（\(detail)）")
        }
    }
}
