@testable import AskHub
import AskHubKit
import Foundation
import Testing

@MainActor
struct LoopStatusModelTests {
    private struct FailingSource: LoopStatusSource {
        func loopStatusRepositories(org: String) async throws -> [LoopStatusRepository] {
            throw GitHubError.http(status: 401, message: nil)
        }
    }

    @Test func loadsSampleRowsCoveringEveryStatus() async {
        let model = LoopStatusModel.sample()
        await model.refresh()
        #expect(model.state == .loaded)
        #expect(model.rows.count == 10)
        let now = Date()
        let displays = model.rows.map { $0.display(now: now) }
        #expect(displays.contains { $0.isStuck })
        #expect(displays.contains { $0.statusText == "担当 PC なし" })
        #expect(displays.contains { $0.statusText == "状態なし" })
        #expect(displays.contains { $0.statusText.hasPrefix("上限で待機中（") })
        let reported = Set(model.rows.compactMap { row in
            if case let .reported(report) = row.status(now: now) { report.state } else { nil }
        })
        #expect(reported == Set(LoopStatusReport.State.allCases).subtracting([.unknown]))
    }

    @Test func needsToken() async {
        let model = LoopStatusModel(tokenStore: InMemoryTokenStore()) { _ in SampleLoopStatusSource() }
        await model.refresh()
        #expect(model.state == .needsToken)
        #expect(model.rows.isEmpty)
    }

    @Test func reportsFailureWithoutToken() async {
        let model = LoopStatusModel(tokenStore: InMemoryTokenStore(token: "github_pat_secret")) { _ in FailingSource() }
        await model.refresh()
        guard case let .failed(message) = model.state else {
            Issue.record("取得の失敗が状態に出ていない: \(model.state)")
            return
        }
        #expect(!message.contains("github_pat_secret"))
    }

    @Test func refreshIfStaleSkipsRecentRefresh() async throws {
        let model = LoopStatusModel.sample()
        await model.refreshIfStale()
        let lastRefreshed = try #require(model.lastRefreshed)

        await model.refreshIfStale(now: lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval - 1))
        #expect(model.lastRefreshed == lastRefreshed)

        await model.refreshIfStale(now: lastRefreshed.addingTimeInterval(AutoRefresh.minimumInterval))
        #expect(try #require(model.lastRefreshed) > lastRefreshed)
    }
}
