import AskHubKit
import Foundation

/// オーケストレーターが使う GitHub の操作。テストでは差し替える
public protocol OrchestratorGitHub: Sendable {
    /// organization 全体の、`ready-for-loop` が付いた open な Discussion
    func readyForLoopDiscussions(orgs: [String]) async throws -> [ReadyDiscussion]
    /// organization 全体の、`manual-loop` が付いた open な Discussion（手で回す epic）
    func manualLoopDiscussions(orgs: [String]) async throws -> [ManualLoopDiscussion]
    /// Discussion から `ready-for-loop` を外す
    func removeReadyLabel(from discussion: ReadyDiscussion) async throws
    /// org 全体の open な `epic-final` PR のうち、GitHub が既定ブランチとコンフリクトすると判定したもの
    func conflictingEpicFinalPullRequests(orgs: [String]) async throws -> [ConflictingPullRequest]
    /// PR にコメントする
    func comment(onPullRequest number: Int, in repository: String, body: String) async throws
    /// `ready-for-loop` の Discussion にコメントする
    func comment(on discussion: ReadyDiscussion, body: String) async throws
    /// Discussion / PR から `needs-answer` を外す
    func removeNeedsAnswerLabel(from subject: InboxSubject) async throws
    /// Discussion に `ready-for-loop` を付ける（質問がすべて回答されたとき）。既に付いていても失敗しない
    func addReadyLabel(to subject: InboxSubject) async throws
    /// `branch` を head にした PR（閉じたものも含む）。無ければ `nil`
    func existingPullRequest(in repository: String, head branch: String) async throws -> ExistingPullRequest?
    /// `branch` から既定ブランチへの epic の最終 PR を作る。PR の番号を返す
    func createEpicFinalPullRequest(in repository: String, head branch: String, body: String) async throws -> Int
    /// PR に `epic-final` を付ける。既に付いていても失敗しない
    func addEpicFinalLabel(in repository: String, number: Int) async throws
    /// PR の本文を置き換える
    func updatePullRequestBody(in repository: String, number: Int, body: String) async throws
    /// organization 全体の、`idea-request` が付いた open な Issue
    func ideaRequests(orgs: [String]) async throws -> [IdeaRequestIssue]
    /// 依頼 Issue にコメントする
    func comment(on issue: IdeaRequestIssue, body: String) async throws
    /// 依頼 Issue をクローズする（完了として）
    func close(_ issue: IdeaRequestIssue) async throws
    /// 担当リポジトリのラベル `askhub-orchestrator` の説明を書き換える。ラベルが無ければ作る
    func updateHeartbeat(in repository: String, description: String) async throws
    /// リポジトリの、`decision-log` が付いた open な Issue（仮決め一覧）
    func decisionLogs(in repository: String) async throws -> [DecisionLogIssue]
    /// Issue のコメント（古い順）
    func comments(in repository: String, issue number: Int) async throws -> [IssueComment]
    /// 仮決め一覧にコメントする
    func comment(on issue: DecisionLogIssue, body: String) async throws
    /// 仮決め一覧をクローズする（完了として）
    func close(_ issue: DecisionLogIssue) async throws
    /// リポジトリの、`loop-status` が付いた Issue（閉じたものも含む）
    func loopStatusIssues(in repository: String) async throws -> [LoopStatusIssueRecord]
    /// 状態用の Issue を作る（ラベルが無ければ作る）。Issue の番号を返す
    func createLoopStatusIssue(in repository: String, body: String) async throws -> Int
    /// 状態用の Issue の本文を置き換える。閉じられていれば開き直す
    func updateLoopStatusIssue(in repository: String, number: Int, body: String) async throws
}

/// 終わるまで待って実行したコマンドの結果
public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    /// 標準出力と標準エラー
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// 既にある PR
public struct ExistingPullRequest: Sendable, Equatable {
    public let number: Int
    public let isOpen: Bool
    /// PR の本文。空なら `nil`
    public let body: String?
    /// マージ済み
    public let isMerged: Bool

    public init(number: Int, isOpen: Bool, body: String? = nil, isMerged: Bool = false) {
        self.number = number
        self.isOpen = isOpen
        self.body = body
        self.isMerged = isMerged
    }
}

/// ループの状態の取得と起動。テストでは差し替える
public protocol LoopRuntime: Sendable {
    func status(of repository: RepositoryConfig) async -> LoopStatus
    /// `arguments` をシェルを経由せずに実行する。終了は待たない。
    /// `environment` は、この起動にだけ追加で渡す環境変数（起動の理由を起動スクリプトに伝えるのに使う）
    func launch(_ arguments: [String], environment: [String: String], for repository: RepositoryConfig) async throws
    /// 制御用 worktree のブランチ・ゴール・state を読む
    func epicSnapshot(of repository: RepositoryConfig) async -> EpicSnapshot
    /// 最新のループ（準備を含む）が Claude の利用上限で終わっていれば、解除の時刻。そうでなければ `nil`
    func usageLimitReset(of repository: RepositoryConfig) async -> Date?
    /// ループのプロセスが生きているのに、今の周回が `timeout` より長く進んでいなければ、そのプロセス
    func hungLoop(of repository: RepositoryConfig, timeout: Duration, now: Date) async -> HungLoop?
    /// 固まったループのプロセスを止める（SIGTERM、猶予の後も残れば SIGKILL）
    func terminate(_ loop: HungLoop) async
    /// 「goal にタスクが無かった」目印を消す（Discussion に知らせた後。追記してラベルを付け直せば、もう一度準備する）
    func clearNoTasksMarker(of repository: RepositoryConfig) async
    /// ループが最後に動いた時刻（state ファイル・goal・最新のログの更新時刻のうち新しいもの）。無ければ `nil`
    func lastActivity(of repository: RepositoryConfig) async -> Date?
    /// `arguments` をシェルを経由せずに実行し、終わるまで待つ。`input` は標準入力に渡す。`timeout` を過ぎたら止める
    func run(_ arguments: [String], input: String, for repository: RepositoryConfig, timeout: Duration) async throws -> CommandResult
}

extension LoopRuntime {
    /// 追加の環境変数なしで `arguments` を実行する。終了は待たない
    public func launch(_ arguments: [String], for repository: RepositoryConfig) async throws {
        try await launch(arguments, environment: [:], for: repository)
    }
}

/// 「ポーリング → 状態判定 → アクション」を繰り返す。
/// 起動した Discussion（`LaunchTracker`）と回答済みの質問（`ResumeWatcher`）を覚えておくため actor にする
public actor Orchestrator {
    /// 今の設定。`configStore` があれば、ポーリングのたびに読み直す
    var config: OrchestratorConfig
    /// 設定の読み直しと担当リポジトリの書き換え。`nil` なら起動時の設定のまま動く
    let configStore: (any OrchestratorConfigStore)?
    /// 最後に読み直しに失敗した理由。同じ失敗をポーリングのたびにログに出さない
    var lastReloadFailure: String?
    let github: any OrchestratorGitHub
    private let inbox: any InboxSource
    let runtime: any LoopRuntime
    let log: @Sendable (String) -> Void
    var tracker = LaunchTracker()
    private var watcher = ResumeWatcher()
    /// epic の最終 PR を作った（または既にあった）リポジトリ。毎回 GitHub に問い合わせないために覚える
    var finalizedEpics: Set<String> = []
    /// 仮決め一覧への指示を受けてループを再開した epic。再び完了したら、最終 PR の本文を書き直す
    var epicsToRefresh: Set<String> = []
    /// 処理済みとして扱う仮決め一覧のコメント（`<repo小文字>#<コメント id>`）。同じコメントで何度も再開しない。
    /// ループの開始を確かめてから（または上限まで試して諦めてから）入れる
    var resumedDecisionComments: Set<String> = []
    /// 仮決め一覧への指示でループを起動し、開始をまだ確かめていないもの（キーは担当リポジトリの `fullName` を小文字にしたもの）
    var pendingDecisionResumes: [String: DecisionLogResume] = [:]
    /// 担当の印を最後に書いた時刻（キーは担当リポジトリの `fullName` を小文字にしたもの）
    var lastHeartbeats: [String: Date] = [:]
    /// Claude の利用上限の解除の時刻。それまでこの Mac のループの起動・再開を止める（アカウントは Mac ごとに共通）
    var usageLimitedUntil: Date?
    let now: @Sendable () -> Date
    var ideaTracker = IdeaRequestTracker()
    var conflictTracker = ConflictTracker()
    var stallWatcher = StallWatcher()
    /// 状態用の Issue に書いた内容
    var loopStatusPublisher = LoopStatusPublisher()
    /// 担当リポジトリごとの、まだ起動していない `ready-for-loop` の Discussion の番号（最後に取得できたもの）
    var readyDiscussionNumbers: [String: Int] = [:]
    /// epic の最終 PR がマージ済みか（キーは `<repo小文字> <branch>`）。未マージなら確かめた時刻も持ち、問い合わせを間引く
    var epicMergeChecks: [String: (merged: Bool, checkedAt: Date)] = [:]

    /// 依頼から Discussion を作らせるコマンドの制限時間
    static let ideaCommandTimeout: Duration = .seconds(30 * 60)

    /// - Parameters:
    ///   - inbox: `needs-answer` の Discussion / PR と質問の取得元
    ///   - configStore: 設定の読み直しと担当リポジトリの書き換え（担当リポジトリの作成・削除の依頼に使う）
    public init(
        config: OrchestratorConfig,
        github: any OrchestratorGitHub,
        inbox: any InboxSource,
        runtime: any LoopRuntime,
        log: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        configStore: (any OrchestratorConfigStore)? = nil
    ) {
        self.config = config
        self.configStore = configStore
        self.github = github
        self.inbox = inbox
        self.runtime = runtime
        self.log = log
        self.now = now
    }

    /// `pollInterval` ごとにポーリングする。タスクがキャンセルされるまで戻らない。
    /// 1 回のポーリングの失敗（ネットワークの断など）はログに出して次の回に持ち越す
    public func run(sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) async {
        while !Task.isCancelled {
            do {
                try await pollOnce()
            } catch {
                log("ポーリングに失敗しました: \(error)")
            }
            do {
                try await sleep(config.pollInterval)
            } catch {
                return
            }
        }
    }

    /// 1 回分のポーリング。実行した起動判定を返す
    @discardableResult
    public func pollOnce() async throws -> [LaunchDecision] {
        // 手で書き換えた設定も、再起動せずに反映する
        reloadConfig()
        // 固まったループを止める（止めた後は、異常終了したループとして再開する）
        await terminateHungLoops()
        var statuses: [String: LoopStatus] = [:]
        for repository in config.repositories {
            statuses[repository.fullName.lowercased()] = await runtime.status(of: repository)
        }
        // 止まったループが Claude の利用上限で終わっていたら、解除の時刻を担当の印に書いて待つ
        await refreshUsageLimit(statuses: statuses)
        await updateHeartbeats()
        if activeUsageLimit(at: now()) != nil {
            // 最終 PR の作成は claude を使わないので、待っている間も進める
            _ = await finalizeCompletedEpics(statuses: statuses)
            await publishLoopStatuses(statuses: statuses)
            return []
        }

        // ask への回答: 止まっているループを再開し、すべて回答済みなら needs-answer を外す。
        // 失敗しても ready-for-loop の判定は続ける
        do {
            try await handleAnswers(statuses: &statuses)
        } catch {
            log("回答の確認に失敗しました: \(error)")
        }

        // 異常終了したループ（タスクを残したまま止まった）を再開する。
        // 新しい Discussion の起動より先に行い、途中の epic に別の epic を被せない
        await resumeStalledLoops(statuses: &statuses)

        // 仮決め一覧: 最終 PR がマージされたら閉じ、マージ前に付いた指示ではループを再開する
        await handleDecisionLogs(statuses: &statuses)

        // 止まったループの epic が完了していたら、既定ブランチへの最終 PR（epic-final）を作る。
        // 新しい Discussion の起動（前の epic の作業ファイルを退避する）より先に行う
        let unfinalized = await finalizeCompletedEpics(statuses: statuses)

        // ready-for-loop の検索は失敗しうるので、ここまで（回答・異常終了・固まったループの再開と最終 PR）を先に済ませる
        let discussions = try await github.readyForLoopDiscussions(orgs: config.orgs)

        // 起動済みの Discussion: ループの開始を確かめたらラベルを外す
        let snapshots = await epicSnapshots()
        recordReadyDiscussions(discussions, snapshots: snapshots)
        let handled = await advanceLaunchedDiscussions(discussions, statuses: statuses, snapshots: snapshots)

        // 手で回す epic があるリポジトリでは起動しない（Q4）。確かめられなければ、このポーリングでは起動しない
        // （依頼・最終 PR のコンフリクト・ループの状態の書き出しは続ける）
        var decisions: [LaunchDecision] = []
        if let manualLoops = await searchManualLoops() {
            decisions = LaunchPlanner.decide(
                discussions,
                config: config,
                statuses: statuses,
                excluding: tracker.blockedDiscussionIDs.union(handled),
                epicsInProgress: Set(snapshots.filter(\.value.inProgress).keys).union(unfinalized),
                manualLoops: manualLoops
            )
            await carryOut(decisions, statuses: &statuses)
        }

        // 新機能の依頼: claude に質問付きの Discussion を作らせる（1 回のポーリングで 1 件）
        do {
            try await handleIdeaRequests()
        } catch {
            log("依頼の確認に失敗しました: \(error)")
        }
        // 最終 PR のコンフリクトの解消と、ループの状態の書き出し（起動・再開を反映した後）
        await finishPoll(statuses: statuses)
        return decisions
    }

    /// 起動判定のとおりに起動し、起動しない理由をログに出す
    private func carryOut(_ decisions: [LaunchDecision], statuses: inout [String: LoopStatus]) async {
        for decision in decisions {
            switch decision {
            case let .launch(discussion, repository):
                if await launch(discussion, in: repository) {
                    statuses[repository.fullName.lowercased()] = LoopStatus(stateFileExists: false, processAlive: true)
                }

            case let .skip(discussion, reason):
                if let message = Self.describe(reason) {
                    log("\(Self.name(of: discussion)) は起動しません: \(message)")
                }
            }
        }
    }

    /// 担当リポジトリに「担当している」印（最終確認の時刻）を書く。アプリが「担当 PC なし」を判断するのに使う。
    /// 同じリポジトリには `OrchestratorHeartbeat.updateInterval` に 1 回まで
    private func updateHeartbeats() async {
        let current = now()
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            if let last = lastHeartbeats[key], current.timeIntervalSince(last) < OrchestratorHeartbeat.updateInterval {
                continue
            }
            do {
                let description = OrchestratorHeartbeat.description(at: current, usageLimitedUntil: activeUsageLimit(at: current))
                try await github.updateHeartbeat(in: repository.fullName, description: description)
                lastHeartbeats[key] = current
            } catch {
                log("\(repository.fullName) に担当の印を書けませんでした（次のポーリングで再試行します）: \(error)")
            }
        }
    }

    private func handleAnswers(statuses: inout [String: LoopStatus]) async throws {
        var snapshots: [AnswerSnapshot] = []
        for subject in try await inbox.subjectsNeedingAnswer(orgs: config.orgs)
        where config.repository(named: subject.repository) != nil {
            // 1 件の失敗（権限不足など）で、ほかの Discussion / PR の再開とラベルの削除を止めない
            do {
                let threads = try await inbox.questionThreads(of: subject)
                snapshots.append(AnswerSnapshot(subject: subject, threads: threads, trustedAuthors: config.trustedAuthors))
            } catch {
                log("\(subject.repository)#\(subject.number) の質問を取得できませんでした: \(error)")
            }
        }
        for action in watcher.update(snapshots: snapshots, statuses: statuses) {
            switch action {
            case let .removeNeedsAnswer(subject):
                await handleFullyAnswered(subject, addsReadyLabel: true)

            case let .removeNeedsAnswerOfManualLoop(subject):
                await handleFullyAnswered(subject, addsReadyLabel: false)

            case let .resume(key):
                guard let repository = config.repository(named: key) else {
                    continue
                }
                if await resume(repository) {
                    // 同じ周回の ready-for-loop の判定で、二重に起動しない
                    statuses[key] = LoopStatus(stateFileExists: false, processAlive: true)
                }

            case let .giveUp(key, attempts):
                log("\(key) のループの再開を \(attempts) 回確かめられませんでした。次の回答が付くまで再開しません（loopCommand を確認してください）")
            }
        }
    }

    /// 回答を受けてループを再開する。起動できたら `true`
    private func resume(_ repository: RepositoryConfig) async -> Bool {
        let key = repository.fullName.lowercased()
        do {
            // 再開では Discussion を伴わないので `{discussion}` は空になる
            try await runtime.launch(config.loopCommand.render(for: repository), for: repository)
        } catch {
            let entry = watcher.recordLaunchFailure(repositoryKey: key)
            log("\(repository.fullName) のループを再開できませんでした（\(entry.attempts)/\(ResumeWatcher.maxAttempts) 回目）: \(error)")
            return false
        }
        watcher.recordLaunch(repositoryKey: key)
        log("\(repository.fullName) の ask に回答が付いたので、ループを再開しました")
        return true
    }

    /// 回答を受けて再開を待っているリポジトリ（テスト用）
    var pendingResumes: [String: ResumeWatcher.Entry] {
        watcher.resumes
    }

    /// 追跡中の Discussion の状態（テスト用）
    var trackedEntries: [String: LaunchTracker.Entry] {
        tracker.entries
    }

    /// 起動できたら `true`
    private func launch(_ discussion: ReadyDiscussion, in repository: RepositoryConfig) async -> Bool {
        let key = repository.fullName.lowercased()
        do {
            try await runtime.launch(config.loopCommand.render(for: repository, discussionNumber: discussion.number), for: repository)
        } catch {
            let entry = tracker.recordLaunchFailure(of: discussion, repositoryKey: key)
            let next = entry.phase == .gaveUp ? "起動をやめます（ready-for-loop は残します）" : "次のポーリングで再試行します"
            log("\(Self.name(of: discussion)) のループを起動できませんでした（\(entry.attempts)/\(LaunchTracker.maxAttempts) 回目）: \(error)。\(next)")
            return false
        }
        tracker.recordLaunch(of: discussion, repositoryKey: key)
        log("\(Self.name(of: discussion)) のループを起動しました。開始を確かめてから ready-for-loop を外します")
        return true
    }

    func perform(_ action: LaunchTracker.Action) async {
        switch action {
        case let .removeLabel(discussion):
            do {
                try await github.removeReadyLabel(from: discussion)
                tracker.recordLabelRemoved(from: discussion)
                log("\(Self.name(of: discussion)) のループの開始を確かめ、ready-for-loop を外しました")
            } catch {
                // 追跡を続けるので、外せるまで二重に起動せず、次のポーリングで外し直す
                log("\(Self.name(of: discussion)) の ready-for-loop を外せませんでした（次のポーリングで再試行します）: \(error)")
            }

        case let .retry(discussion, attempts):
            log("\(Self.name(of: discussion)) のループの開始を確かめられないままプロセスが終わりました（\(attempts)/\(LaunchTracker.maxAttempts) 回目）。起動し直します")

        case let .giveUp(discussion, attempts):
            log("\(Self.name(of: discussion)) のループの開始を \(attempts) 回確かめられませんでした。起動をやめます（loopCommand を確認してください）")
        }
    }

    private static func name(of discussion: ReadyDiscussion) -> String {
        "\(discussion.repository)#\(discussion.number)"
    }

    /// ログに出す見送りの理由。毎回のポーリングで出るため、人の対応が要るものだけにする
    /// （別の PC の担当・ループの実行中・順番待ちは、待てば解消するので出さない）
    private static func describe(_ reason: LaunchDecision.SkipReason) -> String? {
        switch reason {
        case .notAssigned, .loopRunning, .waitingForAnotherDiscussion, .alreadyLaunched, .epicInProgress:
            nil

        case .untrustedAuthor:
            "Discussion の author が信用する author ではありません"

        case .manualLoop:
            "manual-loop（手で回す）が付いています。ループは手で始めてください"

        case let .manualLoopInProgress(number):
            "同じリポジトリの Discussion #\(number) を手で回しています（manual-loop）。その epic が終わるまで自動では起動しません"

        case .loopStateRemains:
            "制御用 worktree に .claude/ralph-loop.local.md が残っています"

        case .loopStatusUnknown:
            "制御用 worktree の .claude/ralph-loop.local.md の有無を確かめられません（アクセス権を確認してください）"
        }
    }
}
