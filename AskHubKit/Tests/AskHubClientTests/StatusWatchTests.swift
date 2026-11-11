@testable import AskHubClient
import AskHubStateStore
import Foundation
import os
import Testing

/// 非常口の `askhub status --watch`（`StatusWatch`）
struct StatusWatchTests {
    static let now = Date(timeIntervalSince1970: 1_793_757_600)

    func watch(_ script: WatchScript, sleeper: RecordingSleeper) -> StatusWatch {
        StatusWatch(
            interval: .seconds(60),
            sleeper: sleeper,
            now: { Self.now },
            read: { try script.read() },
            output: { script.output($0) },
            problem: { script.problem($0) }
        )
    }

    static func shown(_ report: String) -> String {
        "── \(now.formatted(.iso8601))\n\(report)"
    }

    @Test func showsOnlyChangedReports() async throws {
        let script = WatchScript([.report("a"), .report("a"), .report("b")])
        let sleeper = RecordingSleeper()
        try await watch(script, sleeper: sleeper).run(rounds: 3)
        #expect(script.outputs == [Self.shown("a"), Self.shown("b")])
        // 周ごとに間隔のとおりに待ち、最後の周の後は待たない
        #expect(sleeper.waits == [.seconds(60), .seconds(60)])
    }

    @Test func waitsUntilRateLimitIsLifted() async throws {
        let script = WatchScript([.failure(.rateLimited(retryAfter: .seconds(1_948))), .report("a")])
        let sleeper = RecordingSleeper()
        try await watch(script, sleeper: sleeper).run(rounds: 2)
        #expect(sleeper.waits == [.seconds(1_948)])
        #expect(script.problems.count == 1)
        #expect(script.problems.first?.contains("1948 秒後に読み直す") == true)
        #expect(script.outputs == [Self.shown("a")])
    }

    @Test func waitsIntervalAfterOutages() async throws {
        let script = WatchScript([
            .fileFailure(.store(.serverError(status: 502))),
            .failure(.transport("URLError -1009")),
            // 上限の待ちが間隔より短くても、間隔より短くは待たない
            .failure(.rateLimited(retryAfter: .seconds(5))),
            .report("a")
        ])
        let sleeper = RecordingSleeper()
        try await watch(script, sleeper: sleeper).run(rounds: 4)
        #expect(sleeper.waits == [.seconds(60), .seconds(60), .seconds(60)])
        #expect(script.problems.count == 3)
        #expect(script.outputs == [Self.shown("a")])
    }

    @Test func stopsOnFailuresThatWaitingDoesNotFix() async throws {
        let expired = WatchScript([.failure(.unauthorized), .report("a")])
        let sleeper = RecordingSleeper()
        await #expect(throws: StateStoreError.unauthorized) { try await watch(expired, sleeper: sleeper).run(rounds: 2) }
        let unreadable = WatchScript([.fileFailure(.unreadable(path: "repos/x/y/epics/z/epic.json", .notJSON)), .report("a")])
        await #expect(throws: StateFileStore.Failure.self) { try await watch(unreadable, sleeper: sleeper).run(rounds: 2) }
        #expect(sleeper.waits.isEmpty)
        #expect(expired.outputs.isEmpty && unreadable.outputs.isEmpty)
    }

    @Test func refusesIntervalsShorterThanMinute() throws {
        #expect(try StatusWatch.interval(CommandArguments(["--repo", "shilokuma-inc/askhub-sandbox"])) == nil)
        #expect(try StatusWatch.interval(CommandArguments(["--watch", "60"])) == .seconds(60))
        #expect(throws: CommandArguments.Failure.self) { try StatusWatch.interval(CommandArguments(["--watch", "59"])) }
        #expect(throws: CommandArguments.Failure.self) { try StatusWatch.interval(CommandArguments(["--watch", "1分"])) }
    }
}

/// 1 周に読むもの
enum WatchStep: Sendable {
    case report(String)
    case failure(StateStoreError)
    case fileFailure(StateFileStore.Failure)
}

/// 決まった順に、読んだ中身か失敗を返す。出した中身と知らせを残す
final class WatchScript: Sendable {
    private struct State {
        var steps: [WatchStep]
        var outputs: [String] = []
        var problems: [String] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(_ steps: [WatchStep]) {
        state = OSAllocatedUnfairLock(initialState: State(steps: steps))
    }

    var outputs: [String] {
        state.withLock { $0.outputs }
    }

    var problems: [String] {
        state.withLock { $0.problems }
    }

    func read() throws -> String {
        switch state.withLock({ $0.steps.isEmpty ? nil : $0.steps.removeFirst() }) {
        case let .report(text): return text
        case let .failure(error): throw error
        case let .fileFailure(error): throw error
        case nil: throw CancellationError()
        }
    }

    func output(_ text: String) {
        state.withLock { $0.outputs.append(text) }
    }

    func problem(_ text: String) {
        state.withLock { $0.problems.append(text) }
    }
}

/// 待たずに、待つはずだった時間を残す
final class RecordingSleeper: Sleeper {
    private let state = OSAllocatedUnfairLock<[Duration]>(initialState: [])

    var waits: [Duration] {
        state.withLock { $0 }
    }

    func sleep(for duration: Duration) async throws {
        state.withLock { $0.append(duration) }
    }
}
