import Foundation

/// 対象に加えるときの GitHub 側の準備（`docs/renewal/operations.md` の「対象に加えるときの GitHub 側の準備」）の決まり
public enum SetupPolicy {
    /// ワークフローを直す PR のブランチ（毎回同じ。開いた PR があれば作り直さない）
    public static let workflowBranch = "askhub/setup-workflows"
    /// Discussion の写しに使うカテゴリ（Discussions を有効にすると GitHub が作る既定のカテゴリ）
    public static let discussionCategory = "Ideas"
    /// 今の仕組みのワークフロー（ゴールの Discussion を閉じる）。このファイルと、ralph-kit を呼ぶワークフローを外す
    public static let legacyWorkflowNames: Set<String> = ["close-goal-discussion.yml", "close-goal-discussion.yaml"]
    /// 今の仕組み（ralph-kit）を呼ぶワークフローの目印
    public static let legacyMarkers = ["ralph-kit", "ralph_kit"]
}

/// `repo.json` の `setup`（対象に加えるときの GitHub 側の準備の結果）。司令塔が `addRepository` を処理したとき（加え直したときも）に書く
public struct RepositorySetup: Codable, Equatable, Sendable {
    public enum DiscussionsState: String, Codable, Sendable, CaseIterable {
        /// Discussions が有効で、カテゴリ「Ideas」がある
        case ready
        /// Discussions は有効だが、カテゴリ「Ideas」が無い（人が GitHub の Discussions の画面で作る。API では作れない）
        case missingCategory
        /// 有効にできなかった・確かめられなかった（理由は `problems`）
        case unknown
    }

    /// 準備を流した時刻
    public var updatedAt: Timestamp
    public var discussions: DiscussionsState?
    /// ワークフローの直し。確かめられなかったら nil（理由は `problems`）
    public var workflows: WorkflowSetup?
    /// 準備を止めた・できなかった理由（人が読む文。管理用のトークンが無い など）。無ければ nil
    public var problems: [String]?

    public init(updatedAt: Timestamp, discussions: DiscussionsState? = nil, workflows: WorkflowSetup? = nil, problems: [String]? = nil) {
        self.updatedAt = updatedAt
        self.discussions = discussions
        self.workflows = workflows
        self.problems = problems
    }

    var violations: [String] {
        var violations = workflows?.violations ?? []
        if let problems, problems.isEmpty || problems.contains(where: { $0.isEmpty || $0.unicodeScalars.count > 1_000 }) {
            violations.append("setup.problems は 1 つ以上で、空でなく 1000 文字まで")
        }
        return violations
    }
}

/// ワークフローのファイルを直す、決まった手順の PR（司令塔が管理用のトークンで出し、人が承認してからマージする）
public struct WorkflowSetup: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// 直すところが無い
        case notNeeded
        /// PR を出して、人の承認を待っている
        case open
        case merged
        /// マージせずに閉じられた
        case closed
    }

    public var state: State
    /// PR の番号（`notNeeded` のときは無い）
    public var pullRequest: Int?
    /// PR を出したときの head のコミット。承認（`approveSetupPullRequest`）はこれに結びつく
    public var head: String?
    /// 直したところ
    public var changes: [WorkflowChange]
    /// app-kit に入れ替える PR なら、入れる版と替える待つチェックの名前。入れ替えない PR は nil
    public var appKit: AppKitAdoption?

    public init(state: State, pullRequest: Int? = nil, head: String? = nil, changes: [WorkflowChange] = [], appKit: AppKitAdoption? = nil) {
        self.state = state
        self.pullRequest = pullRequest
        self.head = head
        self.changes = changes
        self.appKit = appKit
    }

    var violations: [String] {
        var violations: [String] = []
        if let pullRequest, pullRequest < 1 { violations.append("setup.workflows.pullRequest は 1 以上") }
        if let head, !AttemptFile.isCommitSHA(head) { violations.append("setup.workflows.head の形が違う") }
        if state != .notNeeded, pullRequest == nil || head == nil { violations.append("setup.workflows の PR の番号と head が無い") }
        if changes.contains(where: { $0.path.isEmpty || $0.path.unicodeScalars.count > 1_000 }) {
            violations.append("setup.workflows.changes の path は空でなく 1000 文字まで")
        }
        if changes.contains(where: { $0.lines.map { $0 < 0 } == true }) { violations.append("setup.workflows.changes の lines は 0 以上") }
        if changes.contains(where: { change in
            change.steps.map { $0.isEmpty || $0.count > 50 || $0.contains { $0.isEmpty || $0.unicodeScalars.count > 200 } } == true
        }) {
            violations.append("setup.workflows.changes の steps は 1〜50 個で、空でなく 200 文字まで")
        }
        let adopts = changes.contains { $0.kind == .adoptAppKit }
        if adopts != (appKit != nil) { violations.append("setup.workflows の adoptAppKit の変更と appKit は一緒に書く") }
        violations += appKit?.violations ?? []
        return violations
    }
}

/// app-kit に入れ替える準備の PR の、入れる版と、名前が変わる待つチェック（`docs/renewal/app-kit.md` の「初めての入れ替え」）
public struct AppKitAdoption: Codable, Equatable, Sendable {
    /// 入れる版のタグ
    public var version: AppKitVersion
    /// 入れる版のコミット（40 桁）
    public var ref: String
    /// 入れ替えで名前が変わる待つチェック（今の名前 → 入れ替えた後の名前）。承認されたら、司令塔がマージの前に、
    /// ルールセットの必須のチェック（保護を掛けていれば）とビルドの設定の `childChecks`・`finalChecks` を新しい名前に替える。替えるものが無ければ nil
    public var renamedChecks: [CheckRename]?

    public init(version: AppKitVersion, ref: String, renamedChecks: [CheckRename]? = nil) {
        self.version = version
        self.ref = ref
        self.renamedChecks = renamedChecks
    }

    var violations: [String] {
        var violations: [String] = []
        if !AttemptFile.isCommitSHA(ref) { violations.append("setup.workflows.appKit.ref の形が違う") }
        if let renamedChecks {
            let names = renamedChecks.flatMap { [$0.from, $0.to] }
            if renamedChecks.isEmpty || renamedChecks.contains(where: { $0.from == $0.to })
                || names.contains(where: { !ProtectionPolicy.problems(ofRequiredChecks: [$0]).isEmpty })
                || Set(renamedChecks.map(\.from)).count != renamedChecks.count {
                violations.append("setup.workflows.appKit.renamedChecks は 1 つ以上で、チェックの名前の形で、今の名前が重ならず、名前が変わる")
            }
        }
        return violations
    }
}

/// 待つチェックの名前の付け替え
public struct CheckRename: Codable, Equatable, Sendable {
    /// 今の名前
    public var from: String
    /// 入れ替えた後の名前
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// ワークフローのファイルの直し 1 つ
public struct WorkflowChange: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// 今の仕組みのワークフローを外す
        case removeLegacy
        /// 待つチェックのワークフローの `paths`・`paths-ignore` を外す
        case removePathFilters
        /// app-kit の写すファイルを版の中身にする・`.github/app-kit.json` を足す
        case adoptAppKit
        /// app-kit に置き換わるファイル（app-kit の `manifest.json` の `replaces`）を外す
        case removeReplaced
    }

    public var kind: Kind
    /// リポジトリの直下からのパス（`.github/workflows/build.yml`）
    public var path: String
    /// 外すファイルの行の数（`removeLegacy`・`removeReplaced`。人が差分の大きさを見る）。数えていなければ nil
    public var lines: Int?
    /// 外すワークフローにしか無い手順の名前（app-kit の再利用ワークフローに同じ名前の手順が無いもの。人が、消える手順を確かめる）。無ければ nil
    public var steps: [String]?

    public init(kind: Kind, path: String, lines: Int? = nil, steps: [String]? = nil) {
        self.kind = kind
        self.path = path
        self.lines = lines
        self.steps = steps
    }
}

/// ワークフローを直す PR のマージを承認する人の意図（`approveSetupPullRequest`）。
/// `target` は `{ "type": "setupPullRequest", "id": "<PR の番号>" }`、`targetVersion` は人が見たときの PR の head のコミット。payload は空
public struct ApproveSetupPullRequestIntent: Equatable, Sendable {
    public static let kind = "approveSetupPullRequest"
    public static let targetType = "setupPullRequest"

    public var repo: RepositoryFullName
    public var pullRequest: Int
    public var head: String
    public var intent: IntentReference

    public init(repo: RepositoryFullName, pullRequest: Int, head: String, intent: IntentReference) {
        self.repo = repo
        self.pullRequest = pullRequest
        self.head = head
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が approveSetupPullRequest でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard let target = envelope.target, target.type == Self.targetType, target.epic == nil, let id = target.id,
              let number = Int(id), number >= 1, String(number) == id else {
            throw .init(detail: "target が setupPullRequest の PR の番号でない")
        }
        guard let head = envelope.targetVersion, AttemptFile.isCommitSHA(head) else {
            throw .init(detail: "targetVersion が PR の head のコミットでない")
        }
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(repo: repo, pullRequest: number, head: head, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var target: IntentEnvelope.Target {
        .init(type: Self.targetType, id: String(pullRequest))
    }
}
