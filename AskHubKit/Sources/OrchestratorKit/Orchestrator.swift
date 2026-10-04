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

/// 「ポーリング → 状態判定 → アクション」を繰り返す
public struct Orchestrator: Sendable {
    private let config: OrchestratorConfig
    private let github: any OrchestratorGitHub
    private let runtime: any LoopRuntime
    private let log: @Sendable (String) -> Void

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

    /// 1 回分のポーリング。実行した判定を返す
    @discardableResult
    public func pollOnce() async throws -> [LaunchDecision] {
        let discussions = try await github.readyForLoopDiscussions(org: config.org)
        var statuses: [String: LoopStatus] = [:]
        for repository in config.repositories {
            statuses[repository.fullName.lowercased()] = await runtime.status(of: repository)
        }
        let decisions = LaunchPlanner.decide(discussions, config: config, statuses: statuses)
        for decision in decisions {
            switch decision {
            case let .launch(discussion, repository):
                await launch(discussion, in: repository)

            case let .skip(discussion, reason):
                if let message = Self.describe(reason) {
                    log("\(discussion.repository)#\(discussion.number) は起動しません: \(message)")
                }
            }
        }
        return decisions
    }

    private func launch(_ discussion: ReadyDiscussion, in repository: RepositoryConfig) async {
        let name = "\(discussion.repository)#\(discussion.number)"
        do {
            try await runtime.launch(config.loopCommand.render(for: repository, discussionNumber: discussion.number), for: repository)
        } catch {
            // ラベルは残し、次のポーリングで再試行する
            log("\(name) のループを起動できませんでした: \(error)")
            return
        }
        log("\(name) のループを起動しました")
        do {
            try await github.removeReadyLabel(from: discussion)
        } catch {
            // 起動したプロセスが生きている間は再起動しない。ラベルは次の起動判定まで残る
            log("\(name) の ready-for-loop を外せませんでした: \(error)")
        }
    }

    /// ログに出す見送りの理由。毎回のポーリングで出るため、人の対応が要るものだけにする
    /// （別の PC の担当・ループの実行中・順番待ちは、待てば解消するので出さない）
    private static func describe(_ reason: LaunchDecision.SkipReason) -> String? {
        switch reason {
        case .notAssigned, .loopRunning, .waitingForAnotherDiscussion:
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
