import AskHubKit
import Foundation

// ループの状態を、担当リポジトリごとの状態用の Issue（loop-status）の本文とループごとのコメントに書き出す。アプリはそれを読む
extension Orchestrator {
    /// 取得した `ready-for-loop` の Discussion のうち、担当リポジトリごとに、まだ起動していない最も古いものを覚える
    func recordReadyDiscussions(_ discussions: [ReadyDiscussion], snapshots: [String: EpicSnapshot]) {
        var numbers: [String: Int] = [:]
        for discussion in discussions {
            // 手で回す・信用しない author の Discussion は起動しないので、この PC の開始待ちとして数えない
            // （手動ループの Discussion に、オーケストレーターの書き手でコメントを書かないため）
            guard let repository = config.repository(named: discussion.repository), !discussion.isManualLoop,
                  trust.authors(for: repository.fullName).contains(discussion.author) else {
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
    /// 本文にはリポジトリ全体の状態を、自動ループの状態はそのループ（Discussion）のコメントに書く。
    /// 書けなかったリポジトリはログに出し、次のポーリングで書き直す
    func publishLoopStatuses(statuses: [String: LoopStatus]) async {
        let current = now()
        // xcb のビルドの情報（イベントで分かる変化）も、状態と同じく変わったときと間隔ごとに載せる
        refreshBuildActivity()
        for repository in config.repositories {
            let key = repository.fullName.lowercased()
            let facts = await loopStatusFacts(of: repository, status: statuses[key] ?? .idle, now: current)
            var loop = LoopStatusSummary.report(for: facts, now: current)
            loop.builds = builds(for: repository)
            let body = RepositoryStatusReport(usageLimitedUntil: activeUsageLimit(at: current), checkedAt: current)
            do {
                try await publish(body, loop: loop, to: repository)
            } catch let GitHubError.rateLimited(retryAfter) {
                loopStatusPublisher.forget(repositoryKey: key, retryAfter: retryAfter, now: current)
                log("\(repository.fullName) にループの状態を書けませんでした（レート制限。\(retryAfter.components.seconds) 秒後に再試行します）")
            } catch {
                loopStatusPublisher.forget(repositoryKey: key)
                log("\(repository.fullName) にループの状態を書けませんでした（次のポーリングで再試行します）: \(error)")
            }
        }
        await publishBuildHosts(now: current)
    }

    private func publish(_ body: RepositoryStatusReport, loop: LoopStatusReport, to repository: RepositoryConfig) async throws {
        let key = repository.fullName.lowercased()
        let manualLoopOpen = manualLoopRepositories.contains(key)
        func actions() -> [LoopStatusPublisher.Action] {
            loopStatusPublisher.actions(
                repositoryKey: key, repository: body, loop: loop, now: body.checkedAt, manualLoopOpen: manualLoopOpen
            )
        }
        var pending = actions()
        // 書き換える前に Issue とコメントを読み直す。手で回すループ（書き手が manual）が本文やその Discussion を書いていれば、そこは書かない
        if LoopStatusPublisher.needsLookUp(before: pending) {
            try await lookUpLoopStatus(of: repository)
            pending = actions()
        }
        // Issue を作ったら、同じポーリングでコメントも書く
        if case let .createIssue(issueBody) = pending.first {
            let number = try await github.createLoopStatusIssue(in: repository.fullName, body: issueBody)
            loopStatusPublisher.recordIssueCreated(number: number, body: body, repositoryKey: key)
            log("\(repository.fullName) にループの状態の Issue #\(number) を作りました")
            pending = actions()
        }
        for action in pending {
            try await perform(action, body: body, loop: loop, in: repository)
        }
    }

    private func lookUpLoopStatus(of repository: RepositoryConfig) async throws {
        let trusted = trust.authors(for: repository.fullName)
        let issues = try await github.loopStatusIssues(in: repository.fullName)
        // コメントを読めなければ、重複したコメントを作らないよう書かない（例外で次のポーリングに持ち越す）
        var comments: [LoopStatusComment] = []
        if let issue = LoopStatusPublisher.issue(in: issues, trustedAuthors: trusted) {
            comments = try await github.loopStatusComments(in: repository.fullName, issue: issue.number)
        }
        loopStatusPublisher.adopt(issues, comments: comments, repositoryKey: repository.fullName.lowercased(), trustedAuthors: trusted)
    }

    private func perform(
        _ action: LoopStatusPublisher.Action, body: RepositoryStatusReport, loop: LoopStatusReport, in repository: RepositoryConfig
    ) async throws {
        let key = repository.fullName.lowercased()
        switch action {
        case .lookUp, .createIssue:
            // 読み直した後・作った後に決め直しているので、ここには来ない
            return

        case let .updateIssue(number, issueBody):
            try await github.updateLoopStatusIssue(in: repository.fullName, number: number, body: issueBody)
            loopStatusPublisher.recordBodyWritten(body, repositoryKey: key)

        case let .createComment(number, commentBody):
            let id = try await github.createLoopStatusComment(in: repository.fullName, issue: number, body: commentBody)
            loopStatusPublisher.recordCommentWritten(loop, id: id, repositoryKey: key)

        case let .updateComment(id, commentBody):
            try await github.updateLoopStatusComment(in: repository.fullName, id: id, body: commentBody)
            loopStatusPublisher.recordCommentWritten(loop, id: id, repositoryKey: key)

        case let .deleteComment(id):
            try await github.deleteLoopStatusComment(in: repository.fullName, id: id)
            loopStatusPublisher.recordCommentDeleted(id: id, repositoryKey: key)
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
