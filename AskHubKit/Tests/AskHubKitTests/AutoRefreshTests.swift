import AskHubKit
import Foundation
import Testing

struct AutoRefreshTests {
    private let lastRefreshed = Date(timeIntervalSince1970: 1_000)

    @Test func refreshesWhenNeverLoaded() {
        #expect(AutoRefresh.isStale(lastRefreshed: nil, now: lastRefreshed))
    }

    @Test func skipsWithinInterval() {
        let now = lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval - 1)
        #expect(!AutoRefresh.isStale(lastRefreshed: lastRefreshed, now: now))
    }

    @Test func refreshesAfterInterval() {
        let now = lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval)
        #expect(AutoRefresh.isStale(lastRefreshed: lastRefreshed, now: now))
    }

    @Test func usesGivenInterval() {
        let now = lastRefreshed.addingTimeInterval(10)
        #expect(AutoRefresh.isStale(lastRefreshed: lastRefreshed, now: now, interval: 10))
        #expect(!AutoRefresh.isStale(lastRefreshed: lastRefreshed, now: now, interval: 11))
    }

    @Test func periodicRefreshIsNotSkippedByMinimumInterval() {
        // 定期の取り直しが、直前の取得とのわずかなずれで「間もない」と判定されて飛ばないこと
        let periodic = TimeInterval(AutoRefresh.foregroundInterval.components.seconds)
        #expect(AutoRefresh.minimumInterval < periodic)
        #expect(AutoRefresh.isStale(lastRefreshed: lastRefreshed, now: lastRefreshed.addingTimeInterval(periodic - 1)))
    }

    @Test func repeatsUntilCancelled() async {
        let (ticks, continuation) = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            await AutoRefresh.repeating(every: .milliseconds(1)) {
                continuation.yield()
            }
        }
        var count = 0
        for await _ in ticks {
            count += 1
            if count == 3 {
                break
            }
        }
        task.cancel()
        // 取り消すと戻る
        await task.value
        #expect(count == 3)
    }

    @Test func waitsForIntervalBeforeFirstRun() async {
        let task = Task {
            var runs = 0
            await AutoRefresh.repeating(every: .seconds(60)) {
                runs += 1
            }
            return runs
        }
        task.cancel()
        #expect(await task.value == 0)
    }
}
