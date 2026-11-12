@testable import AskHub
import Foundation
import Testing

/// デモで最終 PR をマージすると、マージ中からマージ済みに変わり、マージ済みの注記を残すこと
@MainActor
struct DemoMergeTests {
    /// テストで進める時計
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let clock = Clock()

    private func makeService() -> DemoClientService {
        DemoClientService(scenario: .standard, reactionDelay: 10, refreshInterval: .seconds(1)) { [clock] in clock.now }
    }

    /// マージしている間は押せず注記も無い。マージ済みになっても押せず、人がマージしたことと時刻を注記に残す
    @Test
    func mergingTurnsMergedWithNote() async throws {
        let service = makeService()
        let before = try #require(service.state.epic("tsundoku-search")?.finalReview)
        try await service.perform(.acceptAllDecisions(
            epicID: "tsundoku-search",
            headCommit: before.headCommit,
            decisionIDs: before.pendingDecisions.map(\.id)
        ))
        let review = try #require(service.state.epic("tsundoku-search")?.finalReview)
        try await service.perform(.merge(epicID: "tsundoku-search", headCommit: try #require(review.headCommit)))

        let merging = try #require(service.state.epic("tsundoku-search")?.finalReview)
        #expect(merging.state == .merging)
        #expect(!merging.canMerge)
        #expect(merging.mergedNote == nil)

        clock.now.addTimeInterval(20)
        _ = try await service.fetchSnapshot()
        let merged = try #require(service.state.epic("tsundoku-search")?.finalReview)
        guard case let .merged(date, automatic) = merged.state else {
            Issue.record("マージ済みになっていません: \(merged.state)")
            return
        }
        #expect(!automatic)
        #expect(!merged.canMerge)
        #expect(merged.mergedNote == "マージしました（\(RelativeTime.clock(date))）")
    }

    /// 自動でマージした epic は、自動でマージしたことと時刻を注記に残す
    @Test
    func automaticMergeKeepsNote() throws {
        let service = makeService()
        let review = try #require(service.state.epic("habit-review")?.finalReview)
        guard case let .merged(date, automatic) = review.state else {
            Issue.record("マージ済みになっていません: \(review.state)")
            return
        }
        #expect(automatic)
        #expect(!review.canMerge)
        #expect(review.mergedNote == "自動でマージしました（\(RelativeTime.clock(date))）")
    }
}
