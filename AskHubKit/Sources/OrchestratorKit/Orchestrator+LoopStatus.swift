import AskHubKit
import Foundation

// ループの状態を、担当リポジトリごとの状態用の Issue（loop-status）に書き出す。アプリはそれを読む
extension Orchestrator {
    /// 取得した `ready-for-loop` の Discussion のうち、担当リポジトリごとに、まだ起動していない最も古いものを覚える
    func recordReadyDiscussions(_ discussions: [ReadyDiscussion], snapshots: [String: EpicSnapshot]) {
        var numbers: [String: Int] = [:]
        for discussion in discussions {
            guard let repository = config.repository(named: discussion.repository) else {
                continue
            }
            let key = repository.fullName.lowercased()
            // 制御用 worktree が既にこの Discussion から準備を終えていれば、起動済み
            if let snapshot = snapshots[key], snapshot.loopPrepared, snapshot.discussion == discussion.number {
                continue
            }
            numbers[key] = min(numbers[key] ?? discussion.number, discussion.number)
        }
        readyDiscussionNumbers = numbers
    }

    /// 担当リポジトリごとに状態をまとめ、変わったとき（変わらなければ `LoopStatusReport.updateInterval` ごと）に書き出す。
    /// 書けなかったリポジトリはログに出し、次のポーリングで書き直す
    func publishLoopStatuses(statuses: [String: LoopStatus]) async {
        let current = now()
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            let facts = await loopStatusFacts(of: repository, status: statuses[key] ?? .idle, now: current)
            let report = LoopStatusSummary.report(for: facts, now: current)
            do {
                try await publish(report, to: repository)
            } catch let GitHubError.rateLimited(retryAfter) {
                loopStatusPublisher.forget(repositoryKey: key, retryAfter: retryAfter, now: current)
                log("\(repository.fullName) にループの状態を書けませんでした（レート制限。\(retryAfter.components.seconds) 秒後に再試行します）")
            } catch {
                loopStatusPublisher.forget(repositoryKey: key)
                log("\(repository.fullName) にループの状態を書けませんでした（次のポーリングで再試行します）: \(error)")
            }
        }
    }

    private func publish(_ report: LoopStatusReport, to repository: RepositoryConfig) async throws {
        let key = repository.fullName.lowercased()
        let manualLoopOpen = manualLoopRepositories.contains(key)
        var action = loopStatusPublisher.action(repositoryKey: key, report: report, now: report.checkedAt, manualLoopOpen: manualLoopOpen)
        // 書き換える前に Issue を読み直す。手で回すループ（書き手が manual）が書いていれば、その間は書かない
        if Self.needsLookUp(before: action) {
            let issues = try await github.loopStatusIssues(in: repository.fullName)
            loopStatusPublisher.adopt(issues, repositoryKey: key, trustedAuthors: trust.authors(for: repository.fullName))
            action = loopStatusPublisher.action(repositoryKey: key, report: report, now: report.checkedAt, manualLoopOpen: manualLoopOpen)
        }
        switch action {
        case .lookUp, .none:
            return

        case let .create(body):
            let number = try await github.createLoopStatusIssue(in: repository.fullName, body: body)
            loopStatusPublisher.recordWritten(report, number: number, repositoryKey: key)
            log("\(repository.fullName) にループの状態の Issue #\(number) を作りました")

        case let .update(number, body):
            try await github.updateLoopStatusIssue(in: repository.fullName, number: number, body: body)
            loopStatusPublisher.recordWritten(report, number: number, repositoryKey: key)
        }
    }

    private static func needsLookUp(before action: LoopStatusPublisher.Action) -> Bool {
        switch action {
        case .lookUp, .update: true
        case .create, .none: false
        }
    }

    private func loopStatusFacts(of repository: RepositoryConfig, status: LoopStatus, now: Date) async -> LoopStatusFacts {
        let key = repository.fullName.lowercased()
        let snapshot = await runtime.epicSnapshot(of: repository)
        return LoopStatusFacts(
            status: status,
            snapshot: snapshot,
            usageLimitedUntil: activeUsageLimit(at: now),
            gaveUp: stallWatcher.hasGivenUp(repositoryKey: key, snapshot: snapshot)
                || tracker.hasGivenUp(repositoryKey: key)
                || pendingResumes[key]?.phase == .gaveUp,
            readyDiscussion: readyDiscussionNumbers[key],
            hasAnsweredQuestions: pendingResumes[key].map { $0.phase != .gaveUp } ?? false,
            epicMerged: await isEpicMerged(snapshot, in: repository, now: now),
            lastActivityAt: await runtime.lastActivity(of: repository)
        )
    }

    /// 完了した epic の最終 PR がマージ済みか。完了していない epic には問い合わせない。
    /// マージ済みと分かれば覚え、未マージなら `LoopStatusReport.updateInterval` ごとに確かめ直す
    private func isEpicMerged(_ snapshot: EpicSnapshot, in repository: RepositoryConfig, now: Date) async -> Bool {
        guard snapshot.loopPrepared, let branch = snapshot.branch, branch.hasPrefix("epic/"),
              let goal = snapshot.goal, !EpicCompletion.hasUnfinishedTasks(in: goal) else {
            return false
        }
        let key = "\(repository.fullName.lowercased()) \(branch)"
        if let check = epicMergeChecks[key],
           check.merged || now.timeIntervalSince(check.checkedAt) < LoopStatusReport.updateInterval {
            return check.merged
        }
        do {
            let merged = try await github.existingPullRequest(in: repository.fullName, head: branch)?.isMerged == true
            epicMergeChecks[key] = (merged, now)
            return merged
        } catch {
            log("\(repository.fullName) の \(branch) の最終 PR を確かめられませんでした（次のポーリングで再試行します）: \(error)")
            return epicMergeChecks[key]?.merged ?? false
        }
    }
}
