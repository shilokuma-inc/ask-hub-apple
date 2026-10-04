import AskHubKit

/// オーケストレーターが使う GitHub の操作。テストでは差し替える
public protocol OrchestratorGitHub: Sendable {
    /// org 全体の、`ready-for-loop` が付いた open な Discussion
    func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion]
    /// Discussion から `ready-for-loop` を外す
    func removeReadyLabel(from discussion: ReadyDiscussion) async throws
    /// Discussion / PR から `needs-answer` を外す
    func removeNeedsAnswerLabel(from subject: InboxSubject) async throws
    /// `branch` を head にした PR が（閉じたものも含めて）あるか
    func hasPullRequest(in repository: String, head branch: String) async throws -> Bool
    /// `branch` から既定ブランチへの epic の最終 PR を作り、`epic-final` を付ける。PR の番号を返す
    func createEpicFinalPullRequest(in repository: String, head branch: String, body: String) async throws -> Int
}

/// ループの状態の取得と起動。テストでは差し替える
public protocol LoopRuntime: Sendable {
    func status(of repository: RepositoryConfig) async -> LoopStatus
    /// `arguments` をシェルを経由せずに実行する。終了は待たない
    func launch(_ arguments: [String], for repository: RepositoryConfig) async throws
    /// 制御用 worktree のブランチ・ゴール・state を読む
    func epicSnapshot(of repository: RepositoryConfig) async -> EpicSnapshot
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
        return decisions
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
            if try await github.hasPullRequest(in: repository.fullName, head: branch) {
                finalizedEpics.insert(key)
                return
            }
            let number = try await github.createEpicFinalPullRequest(in: repository.fullName, head: branch, body: summary)
            finalizedEpics.insert(key)
            log("\(repository.fullName) の \(branch) が完了したので、最終 PR #\(number)（epic-final）を作りました")
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
