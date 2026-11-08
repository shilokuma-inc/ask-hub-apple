import AskHubProtocol
import Foundation

/// 最終 PR の向き（作業ブランチ → base。`docs/renewal/flows.md` の「最終 PR」）
public struct FinalBranches: Equatable, Sendable {
    /// リポジトリの base（`repo.json` の `build.baseBranch`）。最終 PR の向き先で、リポジトリの事実（CLAUDE.md）もここから読む
    public var base: String
    /// epic の作業ブランチ（`askhub/<epic の id>`）
    public var epic: String

    public init(base: String, epic: String) {
        self.base = base
        self.epic = epic
    }

    public init(base: String, epic: EpicFile) {
        self.init(base: base, epic: epic.branch ?? PrepareWorkspaceRunner.branch(of: epic.id))
    }
}

/// epic の作業場所に取り出した作業ブランチ（最終 PR の前の検証と直しで使う）
public struct CheckedOutEpic: Equatable, Sendable {
    public var repo: RepositoryFullName
    public var directory: URL
    public var branches: FinalBranches
    /// 取り出したときの作業ブランチ（リモート）の先頭
    public var head: String
    /// リポジトリの事実（base の CLAUDE.md の全員向けの事実）。作業場所の CLAUDE.md は Claude が書き換えられるので使わない
    public var facts: String

    public init(repo: RepositoryFullName, directory: URL, branches: FinalBranches, head: String, facts: String = "") {
        self.repo = repo
        self.directory = directory
        self.branches = branches
        self.head = head
        self.facts = facts
    }
}

/// レビュー役の Claude が読む、epic 全体の写し（ジョブのフォルダに取り出す。読むだけ）
public struct FinalReviewCheckout: Equatable, Sendable {
    public var directory: URL
    /// 取り出したコミット
    public var head: String
    /// base との分岐点から head までの差分（epic 全体。最終 PR の差分と同じ）
    public var diff: String
    /// 変わったファイルの一覧（`git diff --stat`）
    public var stat: String
    /// 変わったファイルのパス。名前を変えたものは、元と先の両方を入れる
    public var paths: [String]
    /// Xcode のプロジェクト（`project.pbxproj`）の、足した行と消した行（先頭の `+`・`-` 付き）
    public var projectLines: [String]
    /// リポジトリの事実（base の CLAUDE.md の全員向けの事実）
    public var facts: String

    public init(
        directory: URL,
        head: String,
        diff: String,
        stat: String,
        paths: [String],
        projectLines: [String] = [],
        facts: String = ""
    ) {
        self.directory = directory
        self.head = head
        self.diff = diff
        self.stat = stat
        self.paths = paths
        self.projectLines = projectLines
        self.facts = facts
    }
}

/// 最終 PR の段取りのジョブが使う git の操作。本物は `GitRepositoryWorkspace`（`GitRepositoryWorkspace+Final.swift`）。
///
/// Claude には git を使わせず、commit・push はここでワーカーが行う。force push はしない
public protocol FinalGit: Sendable {
    /// 作業ブランチを、リモートの先頭から epic の作業場所に取り出す。前の試行が残した手元の変更は捨てる
    func checkOutEpic(_ repo: RepositoryFullName, epic: ULID, branches: FinalBranches) async throws(WorkspaceError) -> CheckedOutEpic

    /// 実装の途中の質問の答えで再開するときに、epic の作業場所の作業ブランチを、取り出し直さずに（手元の変更と base の取り込みの途中を残して）使う。
    /// 作業場所が無い・壊れている・作業ブランチを取り出していない・先頭がリモートの作業ブランチと違うときは nil（取り出し直して、直しをやり直させる）
    func reuseEpic(_ repo: RepositoryFullName, epic: ULID, branches: FinalBranches) async throws(WorkspaceError) -> CheckedOutEpic?

    /// base の取り込みの途中で、コンフリクトしたままのファイル（index で解消していないもの）。取り込みの途中でなければ空
    func conflictedPaths(in epic: CheckedOutEpic) async throws(WorkspaceError) -> [String]

    /// 手元の変更をすべてコミットし、作業ブランチを push して、新しい先頭を返す。変更が無ければ、コミットも push もせずに nil を返す
    func commitAndPush(_ epic: CheckedOutEpic, message: String) async throws(WorkspaceError) -> String?

    /// base（リモートの先頭）を、取り出した作業ブランチに取り込み始める。コミットはしない（解消した後に `commitAndPush` がマージのコミットにする）。
    /// コンフリクトしたファイルのパスを返す（無ければ空）。base がもう作業ブランチに入っていれば、何もせずに nil を返す
    func mergeBase(into epic: CheckedOutEpic) async throws(WorkspaceError) -> [String]?

    /// `paths` のうち、コンフリクトの印（`<<<<<<<`・`>>>>>>>` で始まる行）が残っているもの
    func unresolvedConflicts(_ paths: [String], in epic: CheckedOutEpic) async -> [String]

    /// `ancestor` の後から `descendant` までのコミットのメッセージ（新しい順）。`ancestor` が `descendant` の祖先でなければ nil
    func messages(after ancestor: String, upTo descendant: String, in epic: CheckedOutEpic) async throws(WorkspaceError) -> [String]?

    /// `head`（nil なら作業ブランチのリモートの先頭）を、ジョブのフォルダに取り出し（ブランチに乗せない）、base との分岐点からの差分を返す
    func checkOutFinal(
        _ repo: RepositoryFullName,
        job: ULID,
        branches: FinalBranches,
        head: String?
    ) async throws(WorkspaceError) -> FinalReviewCheckout

    /// ジョブのフォルダを片付ける（片付けられなくても止めない）
    func release(_ job: ULID) async

    /// この Mac の epic の作業場所と、手元の epic のブランチ（作業ブランチと子ブランチ）を消す。ほかの epic のものには触れない
    func removeEpic(_ repo: RepositoryFullName, epic: ULID, branch: String) async throws(WorkspaceError)
}
