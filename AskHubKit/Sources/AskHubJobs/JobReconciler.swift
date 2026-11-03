import AskHubProtocol
import Foundation

/// 司令塔が、試行を読んでジョブの状態を決める（ジョブのファイルは司令塔だけが書く）。
///
/// ワーカーは `assigned` のジョブを引き受けるときに、`attempts + 1` 番の試行を「実行中」で作る。司令塔はそれを読んで、
/// ジョブを `running` にし、試行が終われば成功・失敗の扱いを決める。同じ試行の結果を 2 度当てないよう、
/// 当てた試行の番号を `attempts` に持つ
public enum JobReconciler {
    public static func reconcile(
        _ job: JobFile,
        attempts: [AttemptFile],
        mac: MacFile?,
        now: Date,
        policy: FailurePolicy = FailurePolicy(),
        timing: JobTiming = JobTiming()
    ) -> JobFile {
        let ownAttempts = attempts.filter { $0.job == job.id }.sorted { $0.number < $1.number }
        if let finished = finishedBySuccess(job, ownAttempts, now: now) { return finished }
        // 人の意図（やり直す・やめる）を待っているもの、終わったもの、まだ割り当てていないものは、試行では動かさない
        guard [.assigned, .running, .paused].contains(job.state) else { return job }
        guard let latest = ownAttempts.last else { return job }
        // 新しい試行か、前に見た試行（実行中・一時停止中）の続きだけを扱う
        let isNew = latest.number > job.attempts
        let isFollowUp = latest.number == job.attempts && (job.state == .running || job.state == .paused)
        guard isNew || isFollowUp else { return job }

        var next = job
        next.attempts = latest.number
        let earlier = Array(ownAttempts.dropLast().compactMap(earlierFailure))
        switch latest.outcome {
        case .running:
            apply(AttemptLiveness.of(latest, mac: mac, now: now, timing: timing), to: &next) {
                policy.decide(.timeout, retryAt: nil, earlier: earlier, now: now)
            }
        case .succeeded:
            next.state = .succeeded
            next.nextRunAt = nil
        case .failed:
            apply(policy.decide(after: latest, earlier: earlier, mac: mac, now: now, timing: timing), to: &next)
        }
        if next != job { next.updatedAt = Timestamp(now) }
        return next
    }

    /// どの試行でも成功が書かれたら、ジョブは成功にする。時間切れとみなした後に元のワーカーが成功を書いたときも、
    /// 同じ作業をもう一度流さない（人に渡した後に成功したときも、成功で終える）
    private static func finishedBySuccess(_ job: JobFile, _ attempts: [AttemptFile], now: Date) -> JobFile? {
        guard [.assigned, .running, .paused, .waitingHuman].contains(job.state),
              let succeeded = attempts.last(where: { $0.outcome == .succeeded }) else {
            return nil
        }
        var next = job
        next.state = .succeeded
        next.attempts = max(job.attempts, succeeded.number)
        next.nextRunAt = nil
        if next != job { next.updatedAt = Timestamp(now) }
        return next
    }

    /// 実行中の試行の様子を当てる。止まっていれば、時間切れとして `stalled` の扱いを当てる
    private static func apply(_ liveness: AttemptLiveness, to job: inout JobFile, stalled: () -> FailureDecision) {
        switch liveness {
        case .alive: job.state = .running
        case .macOffline: job.state = .paused
        case .stalled: apply(stalled(), to: &job)
        }
    }

    private static func apply(_ decision: FailureDecision, to job: inout JobFile) {
        switch decision {
        case let .retry(at):
            job.state = .assigned
            job.nextRunAt = at
        case .fix:
            // 何回目の直しかは、ワーカーが試行の失敗から同じ決まりで求める
            job.state = .assigned
            job.nextRunAt = nil
        case .human:
            job.state = .waitingHuman
            job.nextRunAt = nil
        case .pause:
            job.state = .paused
        }
    }

    /// それまでの試行の失敗の区分。実行中のまま残った古い試行は、時間切れとして数える
    private static func earlierFailure(_ attempt: AttemptFile) -> FailureClass? {
        switch attempt.outcome {
        case .succeeded: nil
        case .failed: attempt.failure?.failureClass ?? .unexpected
        case .running: .timeout
        }
    }
}

extension AttemptLiveness {
    static func isOnline(_ mac: MacFile, attemptMac: MacName, now: Date, timing: JobTiming) -> Bool {
        mac.mac == attemptMac && !isOlder(mac.seenAt, than: timing.macStaleAfter, now: now)
    }
}

extension FailurePolicy {
    /// 失敗した試行の後の扱い。Mac がオフラインで失敗した試行は、Mac が戻っていれば、一時停止をやめて続きから試す
    func decide(after attempt: AttemptFile, earlier: [FailureClass], mac: MacFile?, now: Date, timing: JobTiming) -> FailureDecision {
        let failure = attempt.failure?.failureClass ?? .unexpected
        if failure == .macOffline, let mac, AttemptLiveness.isOnline(mac, attemptMac: attempt.mac, now: now, timing: timing) {
            return .retry(at: Timestamp(now))
        }
        return decide(failure, retryAt: attempt.failure?.retryAt, earlier: earlier, now: now)
    }
}
