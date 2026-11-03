@testable import AskHubJobs
import AskHubProtocol
import AskHubStateStore
import Foundation
import os
import Testing

struct AttemptRecorderTests {
    private typealias Sample = Fixtures

    /// 呼ぶたびに 1 分進む時計
    final class Clock: Sendable {
        private let minute = OSAllocatedUnfairLock(initialState: 0.0)

        func now() -> Date {
            minute.withLock { value in
                value += 1
                return Sample.time(value)
            }
        }
    }

    private func recorder(_ memory: InMemoryStateStore, mac: MacName = Sample.macbook, clock: Clock = Clock()) -> AttemptRecorder {
        AttemptRecorder(files: StateFileStore(store: memory), mac: mac) { clock.now() }
    }

    private func stored(_ memory: InMemoryStateStore, _ job: JobFile, _ number: Int) async throws -> AttemptFile? {
        try await StateFileStore(store: memory)
            .read(AttemptFile.self, at: StatePath.attempt(job.repo, epic: job.epic, job: job.id, number: number))?.file
    }

    @Test func startsNextAttemptOnlyOnce() async throws {
        let memory = InMemoryStateStore()
        let recorder = recorder(memory)
        let job = Sample.job(attempts: 2)
        let attempt = try await recorder.start(job)
        #expect(attempt.number == 3)
        #expect(attempt.outcome == .running)
        #expect(attempt.mac == Sample.macbook)
        #expect(try await stored(memory, job, 3) == attempt)
        // 同じ番号の試行は 2 度作らない（前に引き受けた・司令塔がまだ読んでいない）
        await #expect(throws: StateFileStore.Failure.alreadyExists) { try await recorder.start(job) }
    }

    @Test func refusesJobsNotAssignedToThisMac() async throws {
        let memory = InMemoryStateStore()
        await #expect(throws: StateFileStore.Failure.self) { try await recorder(memory).start(Sample.job(mac: Sample.macMini)) }
        await #expect(throws: StateFileStore.Failure.self) { try await recorder(memory).start(Sample.job(state: .running)) }
        #expect(await memory.writeCount == 0)
    }

    @Test func beatsAndFinishes() async throws {
        let memory = InMemoryStateStore()
        let recorder = recorder(memory)
        let job = Sample.job()
        let attempt = try await recorder.start(job)
        let beaten = try await recorder.beat(attempt, of: job)
        #expect(beaten.heartbeatAt > attempt.heartbeatAt)
        let failure = AttemptFailure(failureClass: .testFailed, message: "テストが落ちた")
        let finished = try await recorder.finish(attempt, of: job, failure: failure, outputs: .init(pullRequest: 840))
        #expect(finished.outcome == .failed)
        #expect(finished.failure == failure)
        #expect(finished.endedAt != nil)
        #expect(finished.outputs?.pullRequest == 840)
        // 終わった試行は書き換えない
        let again = try await recorder.finish(attempt, of: job, failure: nil)
        #expect(again == finished)
        #expect(try await stored(memory, job, 1) == finished)
    }

    @Test func workerAndCommanderAgreeThroughStateFiles() async throws {
        let memory = InMemoryStateStore()
        let recorder = recorder(memory)
        var job = Sample.job()
        let attempt = try await recorder.start(job)
        let started = try #require(try await stored(memory, job, 1))
        job = JobReconciler.reconcile(job, attempts: [started], mac: Sample.mac(seenMinute: 1), now: Sample.time(2))
        #expect(job.state == .running)
        try await recorder.finish(attempt, of: job, failure: AttemptFailure(failureClass: .buildFailed, message: "ビルドが落ちた"))
        let failed = try #require(try await stored(memory, job, 1))
        job = JobReconciler.reconcile(job, attempts: [failed], mac: Sample.mac(seenMinute: 3), now: Sample.time(4))
        #expect(job.state == .assigned)
        #expect(job.attempts == 1)
        // 直させる 2 回目の試行を引き受けられる
        #expect(try await recorder.start(job).number == 2)
    }
}
