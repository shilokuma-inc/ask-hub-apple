@testable import AskHubJobs
import AskHubProtocol
import Foundation
import Testing

struct LivenessTests {
    /// 1 秒未満の期限も、切り捨てずに比べる
    @Test func comparesSubsecondLimits() {
        var timing = JobTiming()
        timing.attemptStaleAfter = .milliseconds(500)
        timing.heartbeatInterval = .milliseconds(100)
        let attempt = Fixtures.attempt(1)
        // 時刻は秒までしか持たないので、Mac の印は試行の印の 1 秒後にする
        let mac = Fixtures.mac(seenMinute: 1.0 / 60)
        #expect(AttemptLiveness.of(attempt, mac: mac, now: Fixtures.start.addingTimeInterval(0.3), timing: timing) == .alive)
        #expect(AttemptLiveness.of(attempt, mac: mac, now: Fixtures.start.addingTimeInterval(0.7), timing: timing) == .stalled)
    }

    /// 試行の印が古くても、Mac の印が試行の次の印の時刻より後に書かれていなければ、ワーカーごと止まったか分からないので決めない
    @Test func waitsUntilMacBeatsPastAttemptHeartbeat() {
        let attempt = Fixtures.attempt(1)
        let now = Fixtures.time(20)
        #expect(AttemptLiveness.of(attempt, mac: Fixtures.mac(seenMinute: 5), now: now) == .alive)
        #expect(AttemptLiveness.of(attempt, mac: Fixtures.mac(seenMinute: 6), now: now) == .stalled)
        #expect(AttemptLiveness.of(attempt, mac: Fixtures.mac(seenMinute: 5), now: Fixtures.time(36)) == .macOffline)
    }
}

struct FailurePolicyTests {
    private let policy = FailurePolicy()
    private let now = Fixtures.start

    private func decide(_ failure: FailureClass, _ earlier: [FailureClass] = [], retryAt: Timestamp? = nil) -> FailureDecision {
        policy.decide(failure, retryAt: retryAt, earlier: earlier, now: now)
    }

    private func after(minutes: Double) -> FailureDecision {
        .retry(at: Fixtures.stamp(minutes))
    }

    @Test func runnerShortageWaitsLongerWithoutLimit() {
        #expect(decide(.runnerUnavailable) == after(minutes: 10))
        #expect(decide(.runnerUnavailable, [.runnerUnavailable]) == after(minutes: 20))
        #expect(decide(.runnerUnavailable, [.runnerUnavailable, .runnerUnavailable]) == after(minutes: 40))
        #expect(decide(.runnerUnavailable, Array(repeating: .runnerUnavailable, count: 3)) == after(minutes: 60))
        #expect(decide(.runnerUnavailable, Array(repeating: .runnerUnavailable, count: 50)) == after(minutes: 60))
        // 間にほかの失敗があれば、数え直す
        #expect(decide(.runnerUnavailable, [.runnerUnavailable, .testFailed]) == after(minutes: 10))
    }

    @Test func flakyIsRerunOnceThenFixed() {
        #expect(decide(.flaky) == after(minutes: 0))
        #expect(decide(.flaky, [.flaky]) == .fix(round: 1))
        #expect(decide(.flaky, [.flaky, .flaky]) == .fix(round: 2))
        #expect(decide(.flaky, [.flaky, .flaky, .flaky, .flaky]) == .human)
    }

    @Test func fixableFailuresGetThreeRoundsThenHuman() {
        for failure in [FailureClass.buildFailed, .testFailed, .reviewRequired, .conflict] {
            #expect(decide(failure) == .fix(round: 1), "\(failure)")
            #expect(decide(failure, [.testFailed]) == .fix(round: 2), "\(failure)")
            #expect(decide(failure, [.buildFailed, .conflict]) == .fix(round: 3), "\(failure)")
            #expect(decide(failure, [.buildFailed, .conflict, .reviewRequired]) == .human, "\(failure)")
            // 待つだけの失敗は、直しに数えない
            #expect(decide(failure, [.runnerUnavailable, .githubOutage, .usageLimit, .macOffline]) == .fix(round: 1), "\(failure)")
        }
    }

    @Test func usageLimitWaitsUntilReset() {
        #expect(decide(.usageLimit, retryAt: Fixtures.stamp(90)) == after(minutes: 90))
        #expect(decide(.usageLimit) == after(minutes: 60))
    }

    @Test(arguments: [FailureClass.githubOutage, .claudeOutage])
    func outageWaitsLonger(_ outage: FailureClass) {
        #expect(decide(outage) == after(minutes: 1))
        #expect(decide(outage, [outage]) == after(minutes: 2))
        #expect(decide(outage, Array(repeating: outage, count: 9)) == after(minutes: 30))
        // ほかの障害の続きは数えない
        #expect(decide(outage, [outage == .githubOutage ? .claudeOutage : .githubOutage]) == after(minutes: 1))
    }

    @Test func emptyOutageWaitsFallBackToOneMinute() {
        var policy = FailurePolicy()
        policy.outageWaits = []
        #expect(policy.decide(.githubOutage, retryAt: nil, earlier: [.githubOutage], now: now) == after(minutes: 1))
    }

    @Test func timeoutIsRetriedOnceInARow() {
        #expect(decide(.timeout) == after(minutes: 0))
        #expect(decide(.timeout, [.timeout]) == .human)
        #expect(decide(.timeout, [.timeout, .testFailed]) == after(minutes: 0))
    }

    @Test func othersGoToHumanOrPause() {
        #expect(decide(.macOffline) == .pause)
        #expect(decide(.authExpired) == .human)
        #expect(decide(.unexpected) == .human)
    }
}
