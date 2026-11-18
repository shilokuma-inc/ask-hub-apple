@testable import AskHubJobs
import AskHubProtocol
import Foundation
import Testing

struct JobReconcilerTests {
    private typealias Sample = Fixtures

    private func reconcile(_ job: JobFile, _ attempts: [AttemptFile], macSeen: Double? = 0, at minute: Double = 1) -> JobFile {
        JobReconciler.reconcile(job, attempts: attempts, mac: macSeen.map { Sample.mac(seenMinute: $0) }, now: Sample.time(minute))
    }

    @Test func assignedJobWithoutAttemptsIsUnchanged() {
        let job = Sample.job()
        #expect(reconcile(job, []) == job)
    }

    @Test func runningAttemptMakesJobRunningOnce() {
        let running = reconcile(Sample.job(), [Sample.attempt(1)])
        #expect(running.state == .running)
        #expect(running.attempts == 1)
        #expect(running.updatedAt == Sample.stamp(1))
        // 同じ試行を読み直しても変わらない
        #expect(reconcile(running, [Sample.attempt(1, heartbeatMinute: 1)], at: 2) == running)
    }

    @Test func succeededAttemptFinishesJob() {
        let job = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1, heartbeatMinute: 1, succeeded: true)])
        #expect(job.state == .succeeded)
    }

    @Test func failureIsAppliedOnlyOnce() {
        let failed = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1, failure: .testFailed)])
        #expect(failed.state == .assigned)
        #expect(failed.nextRunAt == nil)
        // 同じ失敗を 2 度当てない（待ちの時刻が動き続けない）
        #expect(reconcile(failed, [Sample.attempt(1, failure: .testFailed)], at: 5) == failed)
    }

    @Test func fourthFixableFailureGoesToHuman() {
        let attempts = (1...4).map { Sample.attempt($0, failure: .buildFailed) }
        let job = reconcile(Sample.job(state: .running, attempts: 4), attempts)
        #expect(job.state == .waitingHuman)
    }

    @Test func runnerShortageSchedulesRetry() {
        let job = reconcile(Sample.job(attempts: 0), [Sample.attempt(1, failure: .runnerUnavailable)])
        #expect(job.state == .assigned)
        #expect(job.attempts == 1)
        #expect(job.nextRunAt == Sample.stamp(11))
        // 後で読み直しても、待ちの時刻を延ばさない
        #expect(reconcile(job, [Sample.attempt(1, failure: .runnerUnavailable)], at: 8) == job)
    }

    @Test func usageLimitWaitsForReset() {
        let job = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1, failure: .usageLimit, retryAt: Sample.stamp(300))])
        #expect(job.nextRunAt == Sample.stamp(300))
    }

    @Test func stalledAttemptIsTimedOutThenHuman() {
        // Mac は動いているのに、試行の印が 15 分より古い
        let first = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1)], macSeen: 19, at: 20)
        #expect(first.state == .assigned)
        #expect(first.nextRunAt == Sample.stamp(20))
        #expect(reconcile(first, [Sample.attempt(1)], macSeen: 21, at: 22) == first)
        // 2 回目も止まったら、続けて時間切れなので人へ（1 回目は実行中のまま残っている）
        let second = reconcile(first, [Sample.attempt(1), Sample.attempt(2, startedMinute: 21)], macSeen: 40, at: 41)
        #expect(second.state == .waitingHuman)
        #expect(second.attempts == 2)
    }

    /// 時間切れとみなして試し直しにした後に、元のワーカーが成功を書いたら、もう一度流さずに成功にする
    @Test func lateSuccessAfterTimeoutFinishesJob() {
        let retried = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1)], macSeen: 19, at: 20)
        #expect(retried.state == .assigned)
        let succeeded = reconcile(retried, [Sample.attempt(1, heartbeatMinute: 21, succeeded: true)], macSeen: 21, at: 22)
        #expect(succeeded.state == .succeeded)
        #expect(succeeded.nextRunAt == nil)
        // 次の試行が始まった後でも、前の試行の成功を採る
        let both = [Sample.attempt(1, heartbeatMinute: 21, succeeded: true), Sample.attempt(2, startedMinute: 21)]
        #expect(reconcile(retried, both, macSeen: 21, at: 22).state == .succeeded)
        // 人に渡した後に成功したときも、成功で終える
        let waiting = Sample.job(state: .waitingHuman, attempts: 1)
        #expect(reconcile(waiting, [Sample.attempt(1, succeeded: true)]).state == .succeeded)
    }

    @Test func offlineMacPausesAndResumes() {
        let paused = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1)], macSeen: 0, at: 40)
        #expect(paused.state == .paused)
        // 戻って、同じ試行の印が新しくなれば、実行中に戻す
        let resumed = reconcile(paused, [Sample.attempt(1, heartbeatMinute: 45)], macSeen: 45, at: 46)
        #expect(resumed.state == .running)
    }

    /// ジョブの途中でワーカーごと止まった（閉じた）ら、試行の印が 15 分古くなっても時間切れにせず、Mac の印が 30 分古くなったら一時停止する。
    /// 戻ったが試行は止まったまま（ワーカーを起動し直した）なら、時間切れに数えずに続きから試す（何度止まっても人には渡さない）
    @Test func macStoppedMidJobIsPausedAndRetriedWithoutTimeout() {
        // 試行の最後の印は 0 分、Mac の最後の印は 3 分（試行が次の印を書くはずだった 5 分より前）
        let waiting = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1)], macSeen: 3, at: 20)
        #expect(waiting.state == .running)
        let paused = reconcile(waiting, [Sample.attempt(1)], macSeen: 3, at: 34)
        #expect(paused.state == .paused)
        let retried = reconcile(paused, [Sample.attempt(1)], macSeen: 120, at: 121)
        #expect(retried.state == .assigned)
        #expect(retried.nextRunAt == Sample.stamp(121))
        #expect(reconcile(retried, [Sample.attempt(1)], macSeen: 121, at: 122) == retried)

        let attempts = [Sample.attempt(1), Sample.attempt(2, startedMinute: 122)]
        let pausedAgain = reconcile(retried, attempts, macSeen: 123, at: 160)
        #expect(pausedAgain.state == .paused)
        #expect(pausedAgain.attempts == 2)
        let retriedAgain = reconcile(pausedAgain, attempts, macSeen: 200, at: 201)
        #expect(retriedAgain.state == .assigned)
    }

    /// ワーカーが起動し直して前の試行を「Mac がオフライン」で閉じたら、時間切れに数えずに試し直す。
    /// その後の試行が本当に止まっても、続けて時間切れではないので 1 回は試し直す
    @Test func closedLeftoverIsNotCountedAsTimeout() {
        let closed = [Sample.attempt(1, heartbeatMinute: 10, failure: .macOffline)]
        let retried = reconcile(Sample.job(state: .running, attempts: 1), closed, macSeen: 10, at: 11)
        #expect(retried.state == .assigned)
        let stalled = closed + [Sample.attempt(2, startedMinute: 12)]
        let timedOut = reconcile(retried, stalled, macSeen: 30, at: 31)
        #expect(timedOut.state == .assigned)
        #expect(timedOut.attempts == 2)
    }

    /// Mac の印が、試行が次の印を書くはずだった時刻より後に書かれたら、ワーカーは動いていて試行だけが止まった（時間切れ）
    @Test func stalledOnlyAfterMacBeatsPastAttemptHeartbeat() {
        let waiting = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1)], macSeen: 5, at: 16)
        #expect(waiting.state == .running)
        let timedOut = reconcile(waiting, [Sample.attempt(1)], macSeen: 6, at: 17)
        #expect(timedOut.state == .assigned)
        #expect(timedOut.nextRunAt == Sample.stamp(17))
    }

    @Test func offlineFailureWaitsForMacThenRetries() {
        let paused = reconcile(Sample.job(state: .running, attempts: 1), [Sample.attempt(1, failure: .macOffline)], macSeen: nil, at: 5)
        #expect(paused.state == .paused)
        #expect(reconcile(paused, [Sample.attempt(1, failure: .macOffline)], macSeen: nil, at: 10) == paused)
        let retried = reconcile(paused, [Sample.attempt(1, failure: .macOffline)], macSeen: 30, at: 31)
        #expect(retried.state == .assigned)
        #expect(retried.nextRunAt == Sample.stamp(31))
    }

    @Test(arguments: [JobState.queued, .succeeded, .failed, .waitingHuman, .canceled])
    func settledJobsIgnoreAttempts(state: JobState) {
        let job = Sample.job(state: state)
        #expect(reconcile(job, [Sample.attempt(1, failure: .testFailed), Sample.attempt(2)]) == job)
    }

    @Test(arguments: [JobState.queued, .failed, .canceled])
    func settledJobsIgnoreLateSuccess(state: JobState) {
        let job = Sample.job(state: state)
        #expect(reconcile(job, [Sample.attempt(1, succeeded: true)]) == job)
    }

    @Test func attemptsOfOtherJobsAreIgnored() {
        let job = Sample.job(1)
        #expect(reconcile(job, [Sample.attempt(job: 2, 1)]) == job)
    }
}
