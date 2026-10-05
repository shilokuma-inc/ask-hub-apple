import AskHubKit
import Foundation

/// オーケストレーターが使う GitHub の操作。テストでは差し替える
public protocol OrchestratorGitHub: Sendable {
    /// org 全体の、`ready-for-loop` が付いた open な Discussion
    func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion]
    /// Discussion から `ready-for-loop` を外す
    func removeReadyLabel(from discussion: ReadyDiscussion) async throws
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
    /// org 全体の、`idea-request` が付いた open な Issue
    func ideaRequests(org: String) async throws -> [IdeaRequestIssue]
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
    /// `arguments` をシェルを経由せずに実行する。終了は待たない
    func launch(_ arguments: [String], for repository: RepositoryConfig) async throws
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
    /// `arguments` をシェルを経由せずに実行し、終わるまで待つ。`input` は標準入力に渡す。`timeout` を過ぎたら止める
    func run(_ arguments: [String], input: String, for repository: RepositoryConfig, timeout: Duration) async throws -> CommandResult
}

/// 「ポーリング → 状態判定 → アクション」を繰り返す。
/// 起動した Discussion（`LaunchTracker`）と回答済みの質問（`ResumeWatcher`）を覚えておくため actor にする
public actor Orchestrator {
    let config: OrchestratorConfig
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
    /// ループの再開に使った仮決め一覧のコメント（`<repo小文字>#<コメント id>`）。同じコメントで何度も再開しない
    var resumedDecisionComments: Set<String> = []
    /// 担当の印を最後に書いた時刻（キーは担当リポジトリの `fullName` を小文字にしたもの）
    var lastHeartbeats: [String: Date] = [:]
    /// Claude の利用上限の解除の時刻。それまでこの Mac のループの起動・再開を止める（アカウントは Mac ごとに共通）
    var usageLimitedUntil: Date?
    let now: @Sendable () -> Date
    private var ideaTracker = IdeaRequestTracker()
    var stallWatcher = StallWatcher()

    /// 依頼から Discussion を作らせるコマンドの制限時間
    static let ideaCommandTimeout: Duration = .seconds(30 * 60)

    /// - Parameter inbox: `needs-answer` の Discussion / PR と質問の取得元
    public init(
        config: OrchestratorConfig,
        github: any OrchestratorGitHub,
        inbox: any InboxSource,
        runtime: any LoopRuntime,
        log: @escaping @Sendable (String) -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.config = config
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
        let discussions = try await github.readyForLoopDiscussions(org: config.org)

        // 起動済みの Discussion: ループの開始を確かめたらラベルを外す
        let snapshots = await epicSnapshots()
        let handled = await advanceLaunchedDiscussions(discussions, statuses: statuses, snapshots: snapshots)

        let decisions = LaunchPlanner.decide(
            discussions,
            config: config,
            statuses: statuses,
            excluding: tracker.blockedDiscussionIDs.union(handled),
            epicsInProgress: Set(snapshots.filter(\.value.inProgress).keys).union(unfinalized)
        )
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

        // 新機能の依頼: claude に質問付きの Discussion を作らせる（1 回のポーリングで 1 件）
        do {
            try await handleIdeaRequests()
        } catch {
            log("依頼の確認に失敗しました: \(error)")
        }
        return decisions
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

    private func handleIdeaRequests() async throws {
        let issues = try await github.ideaRequests(org: config.org)
        ideaTracker.prune(keeping: issues)

        // 依頼 Issue への後処理（リンクのコメント・クローズ・失敗の通知）。失敗したら次のポーリングで続きから
        for (issue, followUp) in ideaTracker.followUps(in: issues) {
            await perform(followUp, on: issue)
        }

        guard let (issue, repository) = ideaTracker.next(in: issues, config: config) else {
            return
        }
        let name = "\(issue.repository)#\(issue.number)"
        log("\(name) の依頼から、質問付きの Discussion を作らせます")
        let prompt = IdeaPrompt.make(for: issue, trustedAuthors: config.trustedAuthorLogins)
        let arguments = config.ideaCommand.render(for: repository)
        let reason: String
        do {
            // プロンプト（依頼の本文を含む）は引数ではなく標準入力で渡す
            let result = try await runtime.run(arguments, input: prompt, for: repository, timeout: Self.ideaCommandTimeout)
            if result.status == 0, let url = IdeaPrompt.discussionURL(in: result.output, repository: issue.repository) {
                ideaTracker.recordCreated(url, for: issue)
                log("\(name) の依頼から Discussion を作りました: \(url.absoluteString)")
                await perform(.commentAndClose(url), on: issue)
                return
            }
            // 利用上限で失敗したなら、失敗に数えず解除を待つ
            if recordUsageLimit(in: result.output) {
                log("\(name) の Discussion を作る claude が利用上限で終わりました。解除の後に作り直します")
                return
            }
            reason = "Discussion の URL を受け取れませんでした（終了コード \(result.status)）"
        } catch {
            reason = "ideaCommand を起動できませんでした（\(error)）"
        }
        if ideaTracker.recordFailure(for: issue, reason: reason) {
            log("\(name) の Discussion を \(IdeaRequestTracker.maxAttempts) 回作れなかったので、やめます: \(reason)")
            await perform(.reportFailure(reason: reason), on: issue)
        } else {
            log("\(name) の Discussion を作れませんでした。次のポーリングで再試行します: \(reason)")
        }
    }

    /// 依頼 Issue への後処理を 1 段ずつ進める。コメントを重ねないよう、済んだ段は記録してから次へ進む
    private func perform(_ followUp: IdeaRequestTracker.FollowUp, on issue: IdeaRequestIssue) async {
        let name = "\(issue.repository)#\(issue.number)"
        do {
            switch followUp {
            case let .commentAndClose(url):
                try await github.comment(on: issue, body: """
                    質問付きの Discussion を作りました: \(url.absoluteString)

                    AskHub アプリの「要回答」から回答し、「回答を確定してループを始める」を押してください。（askhub-orchestrator）
                    """)
                ideaTracker.recordCommented(issue)
                try await github.close(issue)
                ideaTracker.recordCompleted(issue)
                log("\(name) に Discussion へのリンクをコメントしてクローズしました")

            case .close:
                try await github.close(issue)
                ideaTracker.recordCompleted(issue)
                log("\(name) をクローズしました")

            case let .reportFailure(reason):
                // 人が気づけるよう、依頼 Issue に書き残す（Issue は開いたまま）
                try await github.comment(on: issue, body: """
                    質問付きの Discussion を作れませんでした（\(IdeaRequestTracker.maxAttempts) 回試行）: \(reason)
                    担当 PC のオーケストレーターのログと ideaCommand の設定を確認してください。（askhub-orchestrator）
                    """)
                ideaTracker.recordFailureReported(issue)
            }
        } catch {
            log("\(name) の後処理に失敗しました（次のポーリングで続きから再試行します）: \(error)")
        }
    }

    private func handleAnswers(statuses: inout [String: LoopStatus]) async throws {
        var snapshots: [AnswerSnapshot] = []
        for subject in try await inbox.subjectsNeedingAnswer(org: config.org)
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
                await handleFullyAnswered(subject)

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

        case .loopStateRemains:
            "制御用 worktree に .claude/ralph-loop.local.md が残っています"

        case .loopStatusUnknown:
            "制御用 worktree の .claude/ralph-loop.local.md の有無を確かめられません（アクセス権を確認してください）"
        }
    }
}

// MARK: - 回答の後処理

extension Orchestrator {
    /// 質問がすべて回答された Discussion / PR の後処理
    private func handleFullyAnswered(_ subject: InboxSubject) async {
        let name = "\(subject.repository)#\(subject.number)"
        // Discussion（※1）の質問がすべて回答されたら、ループを始める（Discussion #1 の Q3 の変更）。
        // ready-for-loop を付けられなければ needs-answer も外さず、次のポーリングで再試行する
        // （先に外すと、この Discussion が回答待ちの検索に出なくなり、二度と付け直せない）
        if subject.kind == .discussion {
            do {
                try await github.addReadyLabel(to: subject)
                log("\(name) の質問がすべて回答されたので、ready-for-loop を付けました（ループを始めます）")
            } catch {
                log("\(name) に ready-for-loop を付けられませんでした（次のポーリングで再試行します）: \(error)")
                return
            }
        }
        do {
            try await github.removeNeedsAnswerLabel(from: subject)
            log("\(name) の質問がすべて回答済みになったので、needs-answer を外しました")
        } catch {
            log("\(name) の needs-answer を外せませんでした（次のポーリングで再試行します）: \(error)")
        }
    }
}
