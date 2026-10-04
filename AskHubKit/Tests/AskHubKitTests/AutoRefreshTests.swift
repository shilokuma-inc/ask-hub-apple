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
}
