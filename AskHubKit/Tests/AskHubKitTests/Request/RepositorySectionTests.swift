import AskHubKit
import Foundation
import Testing

struct RepositorySectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func groupsAssignedFirstKeepingOrder() {
        let sections = RepositorySection.grouping([
            RequestRepository(fullName: "o/dotfiles"),
            RequestRepository(fullName: "o/ask-hub-apple", lastSeen: now.addingTimeInterval(-60)),
            RequestRepository(fullName: "o/stale-ios", lastSeen: now.addingTimeInterval(-OrchestratorHeartbeat.freshness - 1)),
            RequestRepository(fullName: "o/notti-ios", lastSeen: now.addingTimeInterval(-OrchestratorHeartbeat.freshness))
        ], now: now)

        #expect(sections == [
            RepositorySection(title: "担当 PC あり", repositories: ["o/ask-hub-apple", "o/notti-ios"]),
            RepositorySection(title: "担当 PC なし", repositories: ["o/dotfiles", "o/stale-ios"])
        ])
    }

    @Test func doesNotSplitWhenAssignmentIsUnknown() {
        let sections = RepositorySection.grouping([
            RequestRepository(fullName: "o/ask-hub-apple", isAssignmentKnown: false),
            RequestRepository(fullName: "o/dotfiles", isAssignmentKnown: false)
        ], now: now)

        #expect(sections == [RepositorySection(title: "担当 PC の有無を確認できませんでした", repositories: ["o/ask-hub-apple", "o/dotfiles"])])
    }

    @Test func omitsEmptySections() {
        #expect(RepositorySection.grouping([], now: now).isEmpty)
        #expect(
            RepositorySection.grouping([RequestRepository(fullName: "o/dotfiles")], now: now)
                == [RepositorySection(title: "担当 PC なし", repositories: ["o/dotfiles"])]
        )
        #expect(
            RepositorySection.grouping([RequestRepository(fullName: "o/notti-ios", lastSeen: now)], now: now)
                == [RepositorySection(title: "担当 PC あり", repositories: ["o/notti-ios"])]
        )
    }
}
