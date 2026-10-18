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

        // owner が 1 つだけでも見出しに owner 名を出す（Discussion #572 Q2）
        #expect(sections == [
            RepositorySection(title: "担当 PC あり・o", repositories: ["o/ask-hub-apple", "o/notti-ios"]),
            RepositorySection(title: "担当 PC なし・o", repositories: ["o/dotfiles", "o/stale-ios"])
        ])
    }

    @Test func splitsEachAssignmentGroupByOwnerInFirstSeenOrder() {
        let sections = RepositorySection.grouping([
            RequestRepository(fullName: "shilokuma-inc/dotfiles"),
            RequestRepository(fullName: "other-org/web", lastSeen: now),
            RequestRepository(fullName: "shilokuma-inc/ask-hub-apple", lastSeen: now),
            RequestRepository(fullName: "other-org/api"),
            RequestRepository(fullName: "shilokuma-inc/notti-ios", lastSeen: now)
        ], now: now)

        // 担当 PC の有無を先に分け、その中を owner が最初に出てきた順に分ける。Section の中は元の順のまま
        #expect(sections == [
            RepositorySection(title: "担当 PC あり・other-org", repositories: ["other-org/web"]),
            RepositorySection(title: "担当 PC あり・shilokuma-inc", repositories: ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/notti-ios"]),
            RepositorySection(title: "担当 PC なし・shilokuma-inc", repositories: ["shilokuma-inc/dotfiles"]),
            RepositorySection(title: "担当 PC なし・other-org", repositories: ["other-org/api"])
        ])
        // Picker の Section の id（＝見出し）が重ならない
        #expect(Set(sections.map(\.id)).count == sections.count)
    }

    @Test func splitsOnlyByOwnerWhenAssignmentIsUnknown() {
        let sections = RepositorySection.grouping([
            RequestRepository(fullName: "o/ask-hub-apple", isAssignmentKnown: false),
            RequestRepository(fullName: "p/web", isAssignmentKnown: false),
            RequestRepository(fullName: "o/dotfiles", isAssignmentKnown: false)
        ], now: now)

        // 「担当 PC なし」と誤って見せない（PR #136）
        #expect(sections == [
            RepositorySection(title: "担当 PC の有無を確認できませんでした・o", repositories: ["o/ask-hub-apple", "o/dotfiles"]),
            RepositorySection(title: "担当 PC の有無を確認できませんでした・p", repositories: ["p/web"])
        ])
    }

    @Test func doesNotSplitByAssignmentWhenAnyAssignmentIsUnknown() {
        let sections = RepositorySection.grouping([
            RequestRepository(fullName: "o/ask-hub-apple", lastSeen: now),
            RequestRepository(fullName: "o/dotfiles", isAssignmentKnown: false)
        ], now: now)

        #expect(sections == [
            RepositorySection(title: "担当 PC の有無を確認できませんでした・o", repositories: ["o/ask-hub-apple", "o/dotfiles"])
        ])
    }

    @Test func omitsEmptySections() {
        #expect(RepositorySection.grouping([], now: now).isEmpty)
        #expect(
            RepositorySection.grouping([RequestRepository(fullName: "o/dotfiles")], now: now)
                == [RepositorySection(title: "担当 PC なし・o", repositories: ["o/dotfiles"])]
        )
        #expect(
            RepositorySection.grouping([RequestRepository(fullName: "o/notti-ios", lastSeen: now)], now: now)
                == [RepositorySection(title: "担当 PC あり・o", repositories: ["o/notti-ios"])]
        )
    }

    @Test func byOwnerUsesOwnerAsTitleAndMergesCaseInsensitively() {
        #expect(RepositorySection.byOwner([]).isEmpty)
        #expect(RepositorySection.byOwner(["Shilokuma-Inc/a", "other/b", "shilokuma-inc/c"]) == [
            RepositorySection(title: "Shilokuma-Inc", repositories: ["Shilokuma-Inc/a", "shilokuma-inc/c"]),
            RepositorySection(title: "other", repositories: ["other/b"])
        ])
        #expect(RepositorySection.byOwner(["o/a"], label: "担当 PC あり") == [
            RepositorySection(title: "担当 PC あり・o", repositories: ["o/a"])
        ])
    }
}
