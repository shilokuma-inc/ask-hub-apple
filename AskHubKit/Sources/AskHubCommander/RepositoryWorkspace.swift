import AskHubProtocol
import Foundation

/// Claude に読ませる、対象のリポジトリの作業場所
public struct PreparedWorkspace: Sendable {
    /// 対象のリポジトリの既定のブランチの写し（読むだけ）
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
    func prepare(_ repo: RepositoryFullName) async throws(WorkspaceError) -> PreparedWorkspace

    /// 依頼の添付を置く、Claude が読んでよいフォルダ（ジョブごとに作る）
    func attachmentsDirectory(for job: ULID) async throws(WorkspaceError) -> URL
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
