import AskHubKit
import Foundation

/// オーケストレーターが使う GitHub の操作。テストでは差し替える
public protocol OrchestratorGitHub: Sendable {
    /// org 全体の、`ready-for-loop` が付いた open な Discussion
    func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion]
    /// Discussion から `ready-for-loop` を外す
    func removeReadyLabel(from discussion: ReadyDiscussion) async throws
    /// Discussion / PR から `needs-answer` を外す
    func removeNeedsAnswerLabel(from subject: InboxSubject) async throws
    /// `branch` を head にした PR（閉じたものも含む）。無ければ `nil`
    func existingPullRequest(in repository: String, head branch: String) async throws -> ExistingPullRequest?
    /// `branch` から既定ブランチへの epic の最終 PR を作る。PR の番号を返す
    func createEpicFinalPullRequest(in repository: String, head branch: String, body: String) async throws -> Int
    /// PR に `epic-final` を付ける。既に付いていても失敗しない
    func addEpicFinalLabel(in repository: String, number: Int) async throws
    /// org 全体の、`idea-request` が付いた open な Issue
    func ideaRequests(org: String) async throws -> [IdeaRequestIssue]
    /// 依頼 Issue にコメントする
    func comment(on issue: IdeaRequestIssue, body: String) async throws
    /// 依頼 Issue をクローズする（完了として）
    func close(_ issue: IdeaRequestIssue) async throws
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

    public init(number: Int, isOpen: Bool) {
        self.number = number
        self.isOpen = isOpen
    }
}

/// ループの状態の取得と起動。テストでは差し替える
public protocol LoopRuntime: Sendable {
    func status(of repository: RepositoryConfig) async -> LoopStatus
    /// `arguments` をシェルを経由せずに実行する。終了は待たない
    func launch(_ arguments: [String], for repository: RepositoryConfig) async throws
    /// 制御用 worktree のブランチ・ゴール・state を読む
    func epicSnapshot(of repository: RepositoryConfig) async -> EpicSnapshot
    /// `arguments` をシェルを経由せずに実行し、終わるまで待つ。`input` は標準入力に渡す。`timeout` を過ぎたら止める
    func run(_ arguments: [String], input: String, for repository: RepositoryConfig, timeout: Duration) async throws -> CommandResult
}

/// 「ポーリング → 状態判定 → アクション」を繰り返す。
/// 起動した Discussion（`LaunchTracker`）と回答済みの質問（`ResumeWatcher`）を覚えておくため actor にする
public actor Orchestrator {
    private let config: OrchestratorConfig
    private let github: any OrchestratorGitHub
    private let inbox: any InboxSource
    private let runtime: any LoopRuntime
    private let log: @Sendable (String) -> Void
    private var tracker = LaunchTracker()
    private var watcher = ResumeWatcher()
    /// epic の最終 PR を作った（または既にあった）リポジトリ。毎回 GitHub に問い合わせないために覚える
    private var finalizedEpics: Set<String> = []
    private var ideaTracker = IdeaRequestTracker()

    /// 依頼から Discussion を作らせるコマンドの制限時間
    static let ideaCommandTimeout: Duration = .seconds(30 * 60)

    /// - Parameter inbox: `needs-answer` の Discussion / PR と質問の取得元
    public init(
        config: OrchestratorConfig,
        github: any OrchestratorGitHub,
        inbox: any InboxSource,
        runtime: any LoopRuntime,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.config = config
        self.github = github
        self.inbox = inbox
        self.runtime = runtime
        self.log = log
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
        let discussions = try await github.readyForLoopDiscussions(org: config.org)
        var statuses: [String: LoopStatus] = [:]
        for repository in config.repositories {
            statuses[repository.fullName.lowercased()] = await runtime.status(of: repository)
        }

        // ask への回答: 止まっているループを再開し、すべて回答済みなら needs-answer を外す。
        // 失敗しても ready-for-loop の判定は続ける
        do {
            try await handleAnswers(statuses: &statuses)
        } catch {
            log("回答の確認に失敗しました: \(error)")
        }

        // 起動済みの Discussion: ループの開始を確かめたらラベルを外す
        for action in tracker.update(discussions: discussions, statuses: statuses) {
            await perform(action)
        }

        let decisions = LaunchPlanner.decide(
            discussions,
            config: config,
            statuses: statuses,
            excluding: tracker.blockedDiscussionIDs
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

        // 止まったループの epic が完了していたら、既定ブランチへの最終 PR（epic-final）を作る
        for repository in config.repositories {
            await finalizeEpicIfComplete(repository, status: statuses[repository.fullName.lowercased()] ?? .idle)
        }

        // 新機能の依頼: claude に質問付きの Discussion を作らせる（1 回のポーリングで 1 件）
        do {
            try await handleIdeaRequests()
        } catch {
            log("依頼の確認に失敗しました: \(error)")
        }
        return decisions
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

    private func finalizeEpicIfComplete(_ repository: RepositoryConfig, status: LoopStatus) async {
        let snapshot = await runtime.epicSnapshot(of: repository)
        guard case let .complete(branch, summary) = EpicCompletion(snapshot: snapshot, status: status) else {
            return
        }
        // 同じ epic の PR は 1 回だけ作る。ブランチが変われば（次の epic）改めて判定する
        let key = "\(repository.fullName.lowercased()) \(branch)"
        guard !finalizedEpics.contains(key) else {
            return
        }
        do {
            // 閉じた PR もあれば作り直さない（人がマージせずに閉じたものを復活させない）
            if let existing = try await github.existingPullRequest(in: repository.fullName, head: branch) {
                // 作った後にラベルだけ付け損ねた場合に備え、open な PR には付け直す（付与は冪等）
                if existing.isOpen {
                    try await github.addEpicFinalLabel(in: repository.fullName, number: existing.number)
                }
                finalizedEpics.insert(key)
                return
            }
            let number = try await github.createEpicFinalPullRequest(in: repository.fullName, head: branch, body: summary)
            log("\(repository.fullName) の \(branch) が完了したので、最終 PR #\(number) を作りました")
            // ラベルの付与に失敗しても、次のポーリングで既存の PR として付け直す
            try await github.addEpicFinalLabel(in: repository.fullName, number: number)
            finalizedEpics.insert(key)
            log("\(repository.fullName) の最終 PR #\(number) に epic-final を付けました")
        } catch {
            log("\(repository.fullName) の \(branch) の最終 PR を作れませんでした（次のポーリングで再試行します）: \(error)")
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
                let name = "\(subject.repository)#\(subject.number)"
                do {
                    try await github.removeNeedsAnswerLabel(from: subject)
                    log("\(name) の質問がすべて回答済みになったので、needs-answer を外しました")
                } catch {
                    log("\(name) の needs-answer を外せませんでした（次のポーリングで再試行します）: \(error)")
                }

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

    private func perform(_ action: LaunchTracker.Action) async {
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
        case .notAssigned, .loopRunning, .waitingForAnotherDiscussion, .alreadyLaunched:
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
