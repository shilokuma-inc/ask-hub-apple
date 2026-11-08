@testable import AskHubJobs
import AskHubProtocol
import Foundation
import Testing

/// 人の一時停止と引き継ぎの後の、ジョブの扱い
struct EpicHoldTests {
    private typealias Sample = Fixtures
    private static let other = MacName(rawValue: "macbook-b")!

    /// Mac がオフラインで止まったジョブは、当てた試行が担当の Mac で止まったもの。人が止めたジョブ・引き継いだジョブは当たらない
    @Test func tellsJobWaitingForOfflineMac() {
        let stalled = [Sample.attempt(1)]
        #expect(Sample.job(state: .paused, attempts: 1).isWaitingForOfflineMac(stalled))
        #expect(Sample.job(state: .paused, attempts: 1).isWaitingForOfflineMac([Sample.attempt(1, failure: .macOffline)]))
        // 人が止めた（試行が無い・前の試行は別の理由で失敗した）
        #expect(!Sample.job(state: .paused).isWaitingForOfflineMac([]))
        #expect(!Sample.job(state: .paused, attempts: 1).isWaitingForOfflineMac([Sample.attempt(1, failure: .testFailed)]))
        // ほかの Mac に引き継いだ
        #expect(!Sample.job(mac: Self.other, state: .paused, attempts: 1).isWaitingForOfflineMac(stalled))
        // 止まっていない
        #expect(!Sample.job(state: .running, attempts: 1).isWaitingForOfflineMac(stalled))
    }

    @Test func holdPausesAssignedJobOnceAndKeepsItWithoutRewriting() {
        let job = Sample.job()
        let held = EpicHold.hold(job, was: job, attempts: [], now: Sample.time(1))
        #expect(held.state == .paused)
        #expect(held.updatedAt == Sample.stamp(1))
        // 止めたまま。待ちの時刻が決め直されても書き直さない
        var redecided = held
        redecided.state = .assigned
        redecided.nextRunAt = Sample.stamp(30)
        #expect(EpicHold.hold(redecided, was: held, attempts: [], now: Sample.time(2)) == held)
        // 動き出した・成功したジョブは止めない
        var running = held
        running.state = .running
        running.attempts = 1
        #expect(EpicHold.hold(running, was: held, attempts: [Sample.attempt(1)], now: Sample.time(2)).state == .running)
    }

    @Test func releaseRestoresOnlyJobsHeldByPause() {
        let held = Sample.job(state: .paused, attempts: 1, nextRunAt: Sample.stamp(20))
        let failed = [Sample.attempt(1, failure: .buildFailed)]
        // 前の失敗で人の対応待ちに決め直されても、止めたときのまま戻す
        var redecided = held
        redecided.state = .waitingHuman
        redecided.nextRunAt = nil
        let released = EpicHold.release(redecided, was: held, attempts: failed, now: Sample.time(3))
        #expect(released.state == .assigned)
        #expect(released.nextRunAt == Sample.stamp(20))
        // オフラインの Mac を待つジョブは戻さない
        let offline = Sample.job(state: .paused, attempts: 1)
        #expect(EpicHold.release(offline, was: offline, attempts: [Sample.attempt(1)], now: Sample.time(3)) == offline)
    }

    @Test func realignMovesIdleJobsOfEpicMac() {
        let attempts = [Sample.attempt(1)]
        // 前の Mac がオフラインで止まったジョブは、前の Mac を待たずに移す先で動かす
        let stuck = Sample.job(state: .paused, attempts: 1, nextRunAt: Sample.stamp(5))
        let moved = EpicHold.realign(stuck, was: stuck, to: Self.other, commander: Sample.macMini, attempts: attempts, now: Sample.time(4))
        #expect(moved.assignedMac == Self.other)
        #expect(moved.state == .assigned)
        #expect(moved.nextRunAt == nil)
        #expect(moved.updatedAt == Sample.stamp(4))
        // 動いているジョブ・司令塔の Mac で動く種類・司令塔の Mac の最終 PR の直しは触らない
        let running = Sample.job(state: .running, attempts: 1)
        #expect(EpicHold.realign(running, was: running, to: Self.other, commander: Sample.macMini, attempts: attempts, now: Sample.time(4)) == running)
        let review = Sample.job(kind: .reviewFinalPullRequest, mac: Sample.macMini)
        #expect(EpicHold.realign(review, was: review, to: Self.other, commander: Sample.macMini, attempts: [], now: Sample.time(4)) == review)
        let fixOnCommander = Sample.job(kind: .fixFinalPullRequest, mac: Sample.macMini)
        let kept = EpicHold.realign(fixOnCommander, was: fixOnCommander, to: Self.other, commander: Sample.macMini, attempts: [], now: Sample.time(4))
        #expect(kept == fixOnCommander)
        let fixOnLaptop = Sample.job(kind: .fixFinalPullRequest, state: .waitingHuman)
        let followed = EpicHold.realign(fixOnLaptop, was: fixOnLaptop, to: Self.other, commander: Sample.macMini, attempts: [], now: Sample.time(4))
        #expect(followed.assignedMac == Self.other)
        #expect(followed.state == .waitingHuman)
    }
}
