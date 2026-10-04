/// オーケストレーターが使う GitHub の操作。テストでは差し替える
public protocol OrchestratorGitHub: Sendable {
    /// org 全体の、`ready-for-loop` が付いた open な Discussion
    func readyForLoopDiscussions(org: String) async throws -> [ReadyDiscussion]
    /// Discussion から `ready-for-loop` を外す
    func removeReadyLabel(from discussion: ReadyDiscussion) async throws
}

/// ループの状態の取得と起動。テストでは差し替える
public protocol LoopRuntime: Sendable {
    func status(of repository: RepositoryConfig) async -> LoopStatus
    /// `arguments` をシェルを経由せずに実行する。終了は待たない
    func launch(_ arguments: [String], for repository: RepositoryConfig) async throws
}

/// 「ポーリング → 状態判定 → アクション」を繰り返す。
/// 起動した Discussion を `LaunchTracker` で覚えておくため actor にする
public actor Orchestrator {
    private let config: OrchestratorConfig
    private let github: any OrchestratorGitHub
    private let runtime: any LoopRuntime
    private let log: @Sendable (String) -> Void
    private var tracker = LaunchTracker()

    public init(
        config: OrchestratorConfig,
        github: any OrchestratorGitHub,
        runtime: any LoopRuntime,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.config = config
        self.github = github
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
                await launch(discussion, in: repository)

            case let .skip(discussion, reason):
                if let message = Self.describe(reason) {
                    log("\(Self.name(of: discussion)) は起動しません: \(message)")
                }
            }
        }
        return decisions
    }

    /// 追跡中の Discussion の状態（テスト用）
    var trackedEntries: [String: LaunchTracker.Entry] {
        tracker.entries
    }

    private func launch(_ discussion: ReadyDiscussion, in repository: RepositoryConfig) async {
        let key = repository.fullName.lowercased()
        do {
            try await runtime.launch(config.loopCommand.render(for: repository, discussionNumber: discussion.number), for: repository)
        } catch {
            let entry = tracker.recordLaunchFailure(of: discussion, repositoryKey: key)
            let next = entry.phase == .gaveUp ? "起動をやめます（ready-for-loop は残します）" : "次のポーリングで再試行します"
            log("\(Self.name(of: discussion)) のループを起動できませんでした（\(entry.attempts)/\(LaunchTracker.maxAttempts) 回目）: \(error)。\(next)")
            return
        }
        tracker.recordLaunch(of: discussion, repositoryKey: key)
        log("\(Self.name(of: discussion)) のループを起動しました。開始を確かめてから ready-for-loop を外します")
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
