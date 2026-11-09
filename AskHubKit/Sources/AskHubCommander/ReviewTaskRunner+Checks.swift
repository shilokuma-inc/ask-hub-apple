import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 子 PR のチェックの待ち方（`docs/renewal/architecture.md` の「失敗の区分と既定の扱い」）
public struct ReviewTiming: Equatable, Sendable {
    /// チェックを読み直す間隔
    public var poll: Duration
    /// ランナー不足のときの待ち。最初の待ちから倍にしていき、上限で止める。回数の上限は無い
    public var shortageFirst: Duration
    public var shortageMax: Duration
    /// queued のままこれより長いチェックは、ランナー不足とみなす
    public var queuedLimit: Duration
    /// 待つチェックがどれも動いていない（まだ出てこない）まま待つ上限
    public var idleLimit: Duration
    /// 落ちたジョブを流し直した後、新しい実行が出てくるのを待つ上限
    public var rerunGrace: Duration
    /// ログを読むときに GitHub の上限に当たったら、待ち時間がこれより短ければ待って読み直す
    public var logRetryLimit: Duration

    public init(
        poll: Duration = .seconds(60),
        shortageFirst: Duration = .seconds(10 * 60),
        shortageMax: Duration = .seconds(60 * 60),
        queuedLimit: Duration = .seconds(30 * 60),
        idleLimit: Duration = .seconds(30 * 60),
        rerunGrace: Duration = .seconds(10 * 60),
        logRetryLimit: Duration = .seconds(5 * 60)
    ) {
        self.poll = poll
        self.shortageFirst = shortageFirst
        self.shortageMax = shortageMax
        self.queuedLimit = queuedLimit
        self.idleLimit = idleLimit
        self.rerunGrace = rerunGrace
        self.logRetryLimit = logRetryLimit
    }
}

/// チェックを待つ PR の呼び名と、待つチェックの設定の名前（失敗の説明に使う）
struct CheckSubject: Equatable {
    var name: String
    var setting: String

    static let child = Self(name: "子 PR", setting: "build.childChecks")
    static let final = Self(name: "最終 PR", setting: "build.finalChecks")
}

/// 子 PR のチェックを待った結果
enum CheckWait: Equatable {
    case passed
    /// 揺らぎの流し直しの後も落ちた（流し直せないものは、流し直さずに）
    case failed([FailedCheck])
}

/// チェックを待っている間の様子
struct CheckWaitState: Equatable {
    /// 流し直した落ちた job の id。新しい実行が出てくるまでは、これらの失敗は古いものとして待つ
    var rerunJobs: Set<Int> = []
    /// 流し直した時刻。流し直しは 1 回だけ
    var rerunAt: Date?
    /// 続けてランナー不足だった回数
    var shortages = 0
    /// 待つチェックがどれも動いていない状態が始まった時刻
    var idleSince: Date?
}

/// 次にすること
enum CheckStep: Equatable {
    case done(CheckWait)
    case wait(Duration)
    /// GitHub Actions の run の、落ちた job を流し直す（揺らぎ）
    case rerun([Int])
    case fail(AttemptFailure)
}

extension ReviewTaskRunner {
    /// PR の head のチェックを、通るか落ちるまで待つ。待つ間は、ワーカー（`JobWorker`）が試行の生きている印を書き続ける
    func waitForChecks(
        _ pulls: any PullRequestOperations,
        head: String,
        required: Set<String>?,
        subject: CheckSubject = .child
    ) async throws(TaskJobExit) -> CheckWait {
        let environment = environment
        let policy = CheckPolicy(required: required, queuedLimit: timing.queuedLimit)
        var state = CheckWaitState()
        while true {
            let summary = try await environment.github("\(subject.name)のチェックを読む") { () throws(PullRequestError) in
                try await pulls.checks(at: head, policy: policy)
            }
            switch Self.next(after: summary, state: &state, timing: timing, now: environment.context.now(), subject: subject) {
            case let .done(wait):
                return wait
            case let .wait(duration):
                try await sleep(for: duration, subject: subject)
            case let .rerun(runs):
                for run in runs {
                    try await environment.github("落ちたジョブを流し直す") { () throws(PullRequestError) in
                        try await pulls.rerunFailedJobs(runID: run)
                    }
                }
                try await sleep(for: timing.poll, subject: subject)
            case let .fail(failure):
                throw .finish(JobResult(failure: failure))
            }
        }
    }

    /// 読んだチェックの様子から、次にすることを決める
    static func next(
        after summary: CheckSummary,
        state: inout CheckWaitState,
        timing: ReviewTiming,
        now: Date,
        subject: CheckSubject = .child
    ) -> CheckStep {
        if summary.verdict != .pending || !summary.unfinished.isEmpty { state.idleSince = nil }
        if summary.verdict != .runnerShortage { state.shortages = 0 }
        switch summary.verdict {
        case .passed:
            return .done(.passed)
        case .pending:
            guard summary.unfinished.isEmpty else { return .wait(timing.poll) }
            let since = state.idleSince ?? now
            state.idleSince = since
            guard now.timeIntervalSince(since) < TaskRunner.seconds(timing.idleLimit) else {
                let names = summary.missing.isEmpty ? "チェック" : "チェック（\(summary.missing.joined(separator: "・"))）"
                return .fail(AttemptFailure(
                    failureClass: .unexpected,
                    message: "\(subject.name)の\(names)が \(timing.idleLimit) 待っても始まらない（repo.json の \(subject.setting) の名前とワークフローを確かめる）"
                ))
            }
            return .wait(timing.poll)
        case .runnerShortage:
            // 人の対応は要らないので、間隔を広げて待ち続ける
            let wait = min(timing.shortageFirst * (1 << min(state.shortages, 16)), timing.shortageMax)
            state.shortages += 1
            return .wait(wait)
        case .failed:
            return failed(summary, state: &state, timing: timing, now: now)
        }
    }

    /// 落ちたチェックがあるとき。終わっていないものを待ち、初めての失敗なら 1 回だけ流し直す
    private static func failed(_ summary: CheckSummary, state: inout CheckWaitState, timing: ReviewTiming, now: Date) -> CheckStep {
        // 直させる前に、まだ動いているものが終わるのを待つ（落ちたものがほかにも出るかもしれない）。
        // ランナー不足で queued のまま上限を超えたものは、いつ始まるか分からないので待たない
        guard summary.unfinished.allSatisfy(summary.starved.contains) else { return .wait(timing.poll) }
        let fresh = summary.failures.filter { failure in failure.jobID.map { !state.rerunJobs.contains($0) } ?? true }
        if let rerunAt = state.rerunAt {
            // 流し直した job の新しい実行が、まだ出てきていない
            if fresh.isEmpty, now.timeIntervalSince(rerunAt) < TaskRunner.seconds(timing.rerunGrace) { return .wait(timing.poll) }
            return .done(.failed(summary.failures))
        }
        var runs: [Int] = []
        for run in fresh.compactMap(\.runID) where !runs.contains(run) {
            runs.append(run)
        }
        // GitHub Actions のほか（commit status）は流し直せない
        guard !runs.isEmpty else { return .done(.failed(summary.failures)) }
        state.rerunJobs = Set(fresh.compactMap(\.jobID))
        state.rerunAt = now
        return .rerun(runs)
    }

    private func sleep(for duration: Duration, subject: CheckSubject) async throws(TaskJobExit) {
        do {
            try await environment.sleeper.sleep(for: duration)
        } catch {
            throw .fail(.macOffline, "ワーカーを止めたので、\(subject.name)のチェックを待つのをやめた")
        }
    }

    /// 落ちたチェックとログの抜粋（`outputs.findings`）。ログを読めなくても、チェックの名前と詳細の URL は渡す
    func ciFindings(_ failures: [FailedCheck], pulls: any PullRequestOperations) async -> String {
        var checks: [FixTaskJob.FailedCheck] = []
        for failure in failures {
            var log: String?
            if let job = failure.jobID {
                log = await readLog(job, pulls: pulls)
            }
            let text = log.map(Self.withoutTimestamps) ?? "（ログを読めなかった。詳細: \(failure.detailsURL?.absoluteString ?? "なし")）"
            let name = "\(failure.name)（\(failure.conclusion)）"
            checks.append(FixTaskJob.FailedCheck(name: name, logExcerpt: Redaction.redact(text, secrets: [])))
        }
        return FixTaskJob.Reason.ci(checks).findings
    }

    /// ログを読む。GitHub の上限に当たったら、待ち時間が `logRetryLimit` までなら 1 回だけ待って読み直す。読めなければ nil
    private func readLog(_ job: Int, pulls: any PullRequestOperations) async -> String? {
        do {
            return try await pulls.jobLog(jobID: job)
        } catch let .rateLimited(wait) where wait <= timing.logRetryLimit {
            guard (try? await environment.sleeper.sleep(for: wait)) != nil else { return nil }
            return try? await pulls.jobLog(jobID: job)
        } catch {
            return nil
        }
    }

    /// GitHub Actions のログの各行の先頭の時刻（`2026-11-07T09:00:00.1234567Z `）を除く
    static func withoutTimestamps(_ log: String) -> String {
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.replacing(#/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z /#, with: "")
        }
        return lines.joined(separator: "\n")
    }
}
