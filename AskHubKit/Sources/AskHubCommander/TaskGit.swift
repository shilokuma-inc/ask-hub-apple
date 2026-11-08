import AskHubProtocol
import Foundation

/// タスクの作業ブランチと子ブランチ（`docs/renewal/flows.md` の「作業ブランチと子 PR」）
public struct TaskBranches: Equatable, Sendable {
    /// リポジトリの base（`repo.json` の `build.baseBranch`）。人がレビューしてマージしたものだけが入るので、リポジトリの事実（CLAUDE.md）はここから読む
    public var base: String
    /// epic の作業ブランチ（`askhub/<epic の id>`）。子 PR の向き先
    public var epic: String
    /// タスクの子ブランチ
    public var task: String

    public init(base: String, epic: String, task: String) {
        self.base = base
        self.epic = epic
        self.task = task
    }

    /// 子ブランチの名前（`<作業ブランチ>-<タスクの id>`）。
    /// `askhub/<epic>/<タスク>` にすると、作業ブランチ `askhub/<epic>` と git の参照の名前がぶつかって作れない
    public static func child(of epicBranch: String, task: String) -> String {
        "\(epicBranch)-\(task)"
    }

    /// epic とタスクの id から決める
    public init(base: String, epic: EpicFile, task: String) {
        let branch = epic.branch ?? PrepareWorkspaceRunner.branch(of: epic.id)
        self.init(base: base, epic: branch, task: Self.child(of: branch, task: task))
    }
}

/// epic の作業場所に取り出した子ブランチ
public struct CheckedOutTask: Equatable, Sendable {
    public var repo: RepositoryFullName
    public var directory: URL
    public var branches: TaskBranches
    /// 取り出したときの子ブランチの先頭（リモートに無ければ、作業ブランチの先頭）
    public var head: String
    /// リモートにあった子ブランチの先頭。無ければ nil（作業ブランチから作った）
    public var remoteHead: String?
    /// 取り出したときの作業ブランチ（リモート）の先頭
    public var base: String
    /// リポジトリの事実（base の CLAUDE.md の全員向けの事実）。作業場所の CLAUDE.md は Claude が書き換えられるので使わない
    public var facts: String

    public init(
        repo: RepositoryFullName,
        directory: URL,
        branches: TaskBranches,
        head: String,
        remoteHead: String?,
        base: String,
        facts: String = ""
    ) {
        self.repo = repo
        self.directory = directory
        self.branches = branches
        self.head = head
        self.remoteHead = remoteHead
        self.base = base
        self.facts = facts
    }
}

/// 子 PR の head を取り出した、レビュー役の Claude が読む作業場所
public struct ReviewCheckout: Equatable, Sendable {
    public var directory: URL
    /// 作業ブランチ（の head との分岐点）から head までの差分
    public var diff: String
    /// 変わったファイルの一覧（`git diff --stat`）
    public var stat: String
    /// リポジトリの事実（base の CLAUDE.md の全員向けの事実）
    public var facts: String

    public init(directory: URL, diff: String, stat: String, facts: String = "") {
        self.directory = directory
        self.diff = diff
        self.stat = stat
        self.facts = facts
    }
}

/// タスクのジョブが epic の作業場所で使う git の操作。本物は `GitRepositoryWorkspace`。
///
/// Claude には git を使わせず、commit・push はここでワーカーが行う。force push はしない
public protocol TaskGit: Sendable {
    /// 子ブランチを epic の作業場所に取り出す。リモートにあればその先頭から（やり直し・ほかの Mac からの引き継ぎ）、無ければ作業ブランチの先頭から作る。
    /// 前の試行が残した手元の変更は捨てる
    func checkOutTask(_ repo: RepositoryFullName, epic: ULID, branches: TaskBranches) async throws(WorkspaceError) -> CheckedOutTask

    /// 実装の途中の質問の答えで再開するときに、epic の作業場所の子ブランチを、取り出し直さずに（手元の変更を残して）使う。
    /// 作業場所が無い・壊れている・子ブランチを取り出していない・先頭が `checkOutTask` で取り出すコミットと違う（質問の後にリモートが動いた・
    /// push していないコミットがある）ときは nil（取り出し直して、変更をやり直させる）
    func reuseTask(_ repo: RepositoryFullName, epic: ULID, branches: TaskBranches) async throws(WorkspaceError) -> CheckedOutTask?

    /// 手元の変更をすべてコミットし、子ブランチを push して、新しい先頭を返す。変更が無ければ、コミットも push もせずに nil を返す
    func commitAndPush(_ task: CheckedOutTask, message: String) async throws(WorkspaceError) -> String?

    /// `ancestor` の後から `descendant` までのコミットのメッセージ（新しい順）。`ancestor` が `descendant` の祖先でなければ nil
    func messages(after ancestor: String, upTo descendant: String, in task: CheckedOutTask) async throws(WorkspaceError) -> [String]?

    /// `ancestor` が `descendant` の祖先（か同じコミット）か
    func isAncestor(_ ancestor: String, of descendant: String, in task: CheckedOutTask) async throws(WorkspaceError) -> Bool

    /// 子 PR の head を epic の作業場所に取り出し（ブランチに乗せない）、作業ブランチからの差分を返す
    func checkOutReview(
        _ repo: RepositoryFullName,
        epic: ULID,
        branches: TaskBranches,
        head: String
    ) async throws(WorkspaceError) -> ReviewCheckout

    /// 人がする作業で渡されたファイルを置くフォルダ（epic の作業場所の外。Claude には `additionalDirectories` で読ませる）。
    /// 前に置いたものは消し、空にして返す。実装の途中の質問の答えで再開したジョブ（別のジョブ）でも同じ場所に置き直せるよう、ジョブではなくタスクで決める
    func handoverDirectory(epic: ULID, task: String) async throws(WorkspaceError) -> URL
}
