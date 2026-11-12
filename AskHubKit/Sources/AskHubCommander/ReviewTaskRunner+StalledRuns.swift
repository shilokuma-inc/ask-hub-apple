import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 待つチェックが出ない PR と、出ていないチェックの名前（失敗の説明に使う）
struct StallTarget: Equatable {
    var pullRequest: Int
    var head: String
    var missing: [String]
    var subject: CheckSubject
}

/// 待つチェックが出ないときに読んだ、head の GitHub Actions の実行
struct RunInspection: Equatable {
    var runs: [WorkflowRun]
    /// queued のまま `stalledAfter` より長く、ジョブが 0 個の実行（見つけた最初の 1 つ）。開き直した後は、その後にできた実行だけを見る
    var stalled: WorkflowRun?
}

/// 実行を読んだ後にすること
enum StallStep: Equatable {
    case wait
    /// GitHub Actions の実行が止まっているので、PR を閉じてすぐ開き直して CI を起こし直す
    case reopen
    case fail(AttemptFailure)
}

/// 待つチェックが出ないとき（`CheckStep.inspectRuns`）。
///
/// GitHub Actions の実行が queued のままジョブが 0 個で止まることがある（GitHub 側の不具合。取り消しも「完了している」と断られる）。
/// 実行が無いのか、止まっているのかを head の実行の一覧で見分け、止まっていれば PR を閉じてすぐ開き直す（`reopened` のイベントで新しい実行が作られる）。
/// 開き直すのは 1 回の待ちで 1 回だけ。設定ミスの案内は、止まった実行が無いときだけ出す
extension ReviewTaskRunner {
    /// 閉じた PR の開き直しを試す回数と、その間の待ち
    static let reopenTries = 3
    static let reopenRetryWait: Duration = .seconds(10)

    /// head の GitHub Actions の実行を読み、止まっていれば PR を開き直して待つ。諦めるときは試行の失敗として投げる
    func inspectRuns(_ pulls: any PullRequestOperations, target: StallTarget, state: inout CheckWaitState) async throws(TaskJobExit) {
        let inspection = try await inspect(pulls, target: target, state: state)
        switch Self.next(after: inspection, target: target, state: &state, timing: timing, now: environment.context.now()) {
        case .wait:
            break
        case .reopen:
            try await reopen(pulls, target: target)
        case let .fail(failure):
            throw .finish(JobResult(failure: failure))
        }
        try await sleep(for: timing.poll, subject: target.subject)
    }

    /// 実行の一覧を読み、止まった実行を探す。ジョブの数は、queued のまま長いものだけを、見つかるまで 1 つずつ読む
    private func inspect(
        _ pulls: any PullRequestOperations,
        target: StallTarget,
        state: CheckWaitState
    ) async throws(TaskJobExit) -> RunInspection {
        let environment = environment
        let runs = try await environment.github("\(target.subject.name)の GitHub Actions の実行を読む") { () throws(PullRequestError) in
            try await pulls.workflowRuns(at: target.head)
        }
        for run in Self.suspects(runs, state: state, timing: timing, now: environment.context.now()) {
            let jobs = try await environment.github("GitHub Actions の実行のジョブを読む") { () throws(PullRequestError) in
                try await pulls.jobCount(runID: run.id)
            }
            if jobs == 0 { return RunInspection(runs: runs, stalled: run) }
        }
        return RunInspection(runs: runs, stalled: nil)
    }

    /// 止まっているかもしれない実行（queued のまま `stalledAfter` より長いもの）。開き直した後は、その後にできた実行だけ（止まった古い実行は残り続ける）
    static func suspects(_ runs: [WorkflowRun], state: CheckWaitState, timing: ReviewTiming, now: Date) -> [WorkflowRun] {
        runs.filter { run in
            guard run.status == "queued", let started = run.startedAt else { return false }
            guard state.reopenedAt == nil || run.id > state.newestRunBeforeReopen else { return false }
            return now.timeIntervalSince(started) >= TaskRunner.seconds(timing.stalledAfter)
        }
    }

    /// 読んだ実行から、次にすることを決める
    static func next(
        after inspection: RunInspection,
        target: StallTarget,
        state: inout CheckWaitState,
        timing: ReviewTiming,
        now: Date
    ) -> StallStep {
        state.inspectedAt = now
        let idle = now.timeIntervalSince(state.idleSince ?? now) >= TaskRunner.seconds(timing.idleLimit)
        let messages = StallMessages(target: target, timing: timing)
        guard let reopenedAt = state.reopenedAt else {
            if let stalled = inspection.stalled {
                // 開き直した後の新しい実行が出るのを、初めから待ち直す
                state.reopenedAt = now
                state.stalledRun = stalled
                state.newestRunBeforeReopen = inspection.runs.map(\.id).max() ?? 0
                state.idleSince = now
                return .reopen
            }
            return idle ? .fail(messages.notStarted(inspection.runs)) : .wait
        }
        if let stalled = inspection.stalled {
            // 新しい実行も止まった。同じ head で自動では開き直し続けない（やり直しの試行のたびに PR を閉じ直さない）ので、人へ渡す
            return .fail(messages.stalledAgain(stalled))
        }
        let fresh = inspection.runs.filter { $0.id > state.newestRunBeforeReopen }
        if fresh.isEmpty, now.timeIntervalSince(reopenedAt) >= TaskRunner.seconds(timing.stalledAfter) {
            return .fail(messages.noNewRun(state.stalledRun))
        }
        return idle ? .fail(messages.notStartedAfterReopen(fresh, stalled: state.stalledRun)) : .wait
    }

    /// CI を起こし直すため、PR を閉じてすぐ開き直す。待っている間に人が閉じた PR は、開き直さずに人へ渡す。
    /// 閉じたまま残さないよう、閉じる要求の応答が失われても閉じたかを読み直し、開き直しに失敗したら少し待って試し直す
    /// （上限なら `Retry-After` まで待つ。ワーカーを止められても試す）。それでも開けなければ人へ渡す
    private func reopen(_ pulls: any PullRequestOperations, target: StallTarget) async throws(TaskJobExit) {
        let name = "\(target.subject.name) #\(target.pullRequest)"
        let current = try await environment.github("\(name) を読む") { () throws(PullRequestError) in
            try await pulls.pullRequest(number: target.pullRequest)
        }
        guard current.state == .open, !current.merged else {
            throw .fail(.unexpected, "\(name) が、チェックを待っている間に閉じられた（開き直さない）")
        }
        do {
            try await pulls.setState(number: target.pullRequest, to: .closed)
        } catch {
            // GitHub が閉じた後に、応答だけが失われたかもしれない。開いたままと分かったときだけ、閉じられなかったとして終える
            if (try? await pulls.pullRequest(number: target.pullRequest))?.state == .open {
                let failure = error.attemptFailure(doing: "CI を起こし直すために\(name) を閉じる", now: environment.context.now())
                throw .finish(JobResult(failure: failure))
            }
        }
        var tries = 0
        while true {
            let wait: Duration
            do {
                try await pulls.setState(number: target.pullRequest, to: .open)
                return
            } catch {
                tries += 1
                guard tries < Self.reopenTries else {
                    throw .fail(.unexpected, "CI を起こし直すために\(name) を閉じたが、開き直せない（\(error)）。GitHub で開き直してから、もう一度試す")
                }
                wait = Self.reopenWait(after: error)
            }
            try? await environment.sleeper.sleep(for: wait)
        }
    }

    /// 開き直しに失敗した後、次に試すまでの待ち。上限なら、GitHub が示す待ち時間（`Retry-After` など）まで待つ
    static func reopenWait(after error: PullRequestError) -> Duration {
        guard case let .rateLimited(retryAfter) = error else { return reopenRetryWait }
        return max(retryAfter, reopenRetryWait)
    }
}

/// 待つチェックが出ないときの失敗の説明
private struct StallMessages {
    var target: StallTarget
    var timing: ReviewTiming

    private var checks: String {
        let names = target.missing.joined(separator: "・")
        return "\(target.subject.name)の" + (names.isEmpty ? "チェック" : "チェック（\(names)）")
    }

    private static func describe(_ run: WorkflowRun) -> String {
        "\(run.name.isEmpty ? "#\(run.id)" : run.name)・\(run.event)"
    }

    private static func describe(_ runs: [WorkflowRun]) -> String {
        runs.prefix(5).map(describe).joined(separator: "、")
    }

    /// 止まった実行は無い。実行が無いか、あっても待つチェックを出さない（設定ミス）
    func notStarted(_ runs: [WorkflowRun]) -> AttemptFailure {
        let detail = runs.isEmpty
            ? "head の GitHub Actions の実行が 1 つも無い（repo.json の \(target.subject.setting) の名前と、ワークフローの起動の条件（on・paths）を確かめる）"
            : "head の GitHub Actions の実行（\(Self.describe(runs))）はあるが、待つチェックが出ない（repo.json の \(target.subject.setting) の名前とワークフローを確かめる）"
        return AttemptFailure(failureClass: .unexpected, message: "\(checks)が \(timing.idleLimit) 待っても始まらない。\(detail)")
    }

    func stalledAgain(_ run: WorkflowRun) -> AttemptFailure {
        let message = "\(target.subject.name)の GitHub Actions の実行（\(Self.describe(run))）が、PR を閉じて開き直した後も queued のままジョブが 0 個で止まっている。"
            + "GitHub 側で実行が止まっている。GitHub の様子（githubstatus.com の Actions）を確かめてから、もう一度試す（もう 1 回開き直す）"
        return AttemptFailure(failureClass: .unexpected, message: message)
    }

    func noNewRun(_ stalled: WorkflowRun?) -> AttemptFailure {
        let run = stalled.map { "（\(Self.describe($0))）" } ?? ""
        let message = "\(target.subject.name)の GitHub Actions の実行\(run)が queued のままジョブが 0 個で止まっていて（GitHub 側で止まっている）、"
            + "PR を閉じて開き直しても新しい実行が作られない。GitHub の Actions で実行の様子を確かめてから、もう一度試す"
        return AttemptFailure(failureClass: .unexpected, message: message)
    }

    func notStartedAfterReopen(_ fresh: [WorkflowRun], stalled: WorkflowRun?) -> AttemptFailure {
        let run = stalled.map { "（\(Self.describe($0))）" } ?? ""
        let message = "\(checks)が始まらない。GitHub Actions の実行\(run)が queued のままジョブが 0 個で止まっていたので PR を閉じて開き直したが、"
            + "その後の実行（\(Self.describe(fresh))）でも \(timing.idleLimit) 待って待つチェックが出ない（repo.json の \(target.subject.setting) の名前とワークフローも確かめる）"
        return AttemptFailure(failureClass: .unexpected, message: message)
    }
}
