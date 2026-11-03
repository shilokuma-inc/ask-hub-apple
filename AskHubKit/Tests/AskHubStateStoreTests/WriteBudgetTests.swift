@testable import AskHubStateStore
import Foundation
import Testing

struct WriteBudgetTests {
    private static let start = Date(timeIntervalSince1970: 1_793_700_000)

    @Test func limitsPerMinute() async throws {
        let budget = WriteBudget(limits: .init(perMinute: 2, perHour: 100))
        try await budget.reserve(now: Self.start)
        try await budget.reserve(now: Self.start.addingTimeInterval(10))
        await #expect(throws: StateStoreError.budgetExhausted(retryAfter: .seconds(30))) {
            try await budget.reserve(now: Self.start.addingTimeInterval(30))
        }
        // 1 分たてば、最初の 1 件の分が空く
        try await budget.reserve(now: Self.start.addingTimeInterval(60))
    }

    @Test func limitsPerHour() async throws {
        let budget = WriteBudget(limits: .init(perMinute: 100, perHour: 3))
        for minute in 0..<3 {
            try await budget.reserve(now: Self.start.addingTimeInterval(Double(minute) * 60))
        }
        await #expect(throws: StateStoreError.budgetExhausted(retryAfter: .seconds(600))) {
            try await budget.reserve(now: Self.start.addingTimeInterval(3000))
        }
        try await budget.reserve(now: Self.start.addingTimeInterval(3600))
    }

    @Test func refusedWritesAreNotCounted() async throws {
        let budget = WriteBudget(limits: .init(perMinute: 1, perHour: 100))
        try await budget.reserve(now: Self.start)
        for second in 1..<5 {
            await #expect(throws: StateStoreError.self) { try await budget.reserve(now: Self.start.addingTimeInterval(Double(second))) }
        }
        try await budget.reserve(now: Self.start.addingTimeInterval(60))
    }

    @Test func presetsFitGitHubContentCreationLimit() {
        // 内容を作る要求の上限（1 分 80 件・1 時間 500 件）に、司令塔 1・ワーカー 3・クライアント 2 で収まる
        let limits = [WriteBudget.Limits.commander] + Array(repeating: .worker, count: 3) + Array(repeating: .client, count: 2)
        #expect(limits.map(\.perMinute).reduce(0, +) <= 80)
        #expect(limits.map(\.perHour).reduce(0, +) <= 500)
    }
}
