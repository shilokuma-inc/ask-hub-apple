@testable import AskHubKit
import Foundation
import Testing

struct InboxIssueListFilterTests {
    private static func issue(
        _ id: String,
        repository: String = "shilokuma-inc/ask-hub-apple",
        created: TimeInterval = 0,
        updated: TimeInterval = 0
    ) -> InboxIssue {
        InboxIssue(
            id: id,
            kind: .needsVerify,
            repository: repository,
            number: 1,
            title: "【CHORE】実機確認: 通知の表示",
            url: URL(string: "https://github.com/\(repository)/issues/1")!,
            author: "mrs1669",
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: updated)
        )
    }

    /// 作成日と更新日の順が食い違う一覧（a: 古く作って最近更新 / b: 最近作って古い更新 / c と d: 同じ日時）
    private static let issues = [
        issue("I_a", created: 100, updated: 900),
        issue("I_b", created: 800, updated: 200),
        issue("I_c", created: 500, updated: 500),
        issue("I_d", created: 500, updated: 500)
    ]

    private static func ids(_ issues: [InboxIssue]) -> [String] {
        issues.map(\.id)
    }

    // MARK: - 並び替え

    @Test func defaultOrderMatchesFetcherOrder() {
        // 既定は InboxFetcher.lowPriorityIssues と同じ並び（更新の新しい順。同じ時刻なら id の降順）
        #expect(InboxIssueSortOrder.default == .updatedNewest)
        let fetcherOrder = Self.issues.sorted { ($0.updatedAt, $0.id) > ($1.updatedAt, $1.id) }
        #expect(Self.ids(InboxIssueSortOrder.default.sorted(Self.issues.shuffled())) == Self.ids(fetcherOrder))
        #expect(Self.ids(InboxIssueSortOrder.updatedNewest.sorted(Self.issues)) == ["I_a", "I_d", "I_c", "I_b"])
    }

    @Test func sortsByEachOrder() {
        #expect(Self.ids(InboxIssueSortOrder.updatedOldest.sorted(Self.issues)) == ["I_b", "I_c", "I_d", "I_a"])
        #expect(Self.ids(InboxIssueSortOrder.createdNewest.sorted(Self.issues)) == ["I_b", "I_d", "I_c", "I_a"])
        #expect(Self.ids(InboxIssueSortOrder.createdOldest.sorted(Self.issues)) == ["I_a", "I_c", "I_d", "I_b"])
    }

    @Test func oldestIsReverseOfNewest() {
        let shuffled = Self.issues.shuffled()
        #expect(InboxIssueSortOrder.updatedOldest.sorted(shuffled) == InboxIssueSortOrder.updatedNewest.sorted(shuffled).reversed())
        #expect(InboxIssueSortOrder.createdOldest.sorted(shuffled) == InboxIssueSortOrder.createdNewest.sorted(shuffled).reversed())
    }

    @Test func orderTitles() {
        #expect(InboxIssueSortOrder.allCases.map(\.title) == [
            "更新日（新しい順）",
            "更新日（古い順）",
            "作成日（新しい順）",
            "作成日（古い順）"
        ])
    }

    // MARK: - 候補

    @Test func optionsCountEachRepository() {
        let issues = [
            Self.issue("I_1", repository: "shilokuma-inc/ralph-kit"),
            Self.issue("I_2", repository: "shilokuma-inc/ask-hub-apple"),
            Self.issue("I_3", repository: "shilokuma-inc/ralph-kit"),
            Self.issue("I_4", repository: "shilokuma-inc/Beat-Tap-ios")
        ]
        #expect(InboxRepositoryOption.options(in: issues) == [
            InboxRepositoryOption(repository: "shilokuma-inc/ask-hub-apple", count: 1, displayName: "ask-hub-apple"),
            InboxRepositoryOption(repository: "shilokuma-inc/Beat-Tap-ios", count: 1, displayName: "Beat-Tap-ios"),
            InboxRepositoryOption(repository: "shilokuma-inc/ralph-kit", count: 2, displayName: "ralph-kit")
        ])
        #expect(InboxRepositoryOption.options(in: []).isEmpty)
    }

    @Test func optionsKeepOwnersApartAndShowFullNameWhenAmbiguous() {
        // 別の owner の同じ名前のリポジトリは混ぜず、見分けられるように owner/repo で出す
        let issues = [
            Self.issue("I_1", repository: "shilokuma-inc/app"),
            Self.issue("I_2", repository: "mrs1669/App"),
            Self.issue("I_3", repository: "shilokuma-inc/app"),
            Self.issue("I_4", repository: "shilokuma-inc/ralph-kit")
        ]
        #expect(InboxRepositoryOption.options(in: issues) == [
            InboxRepositoryOption(repository: "mrs1669/App", count: 1, displayName: "mrs1669/App"),
            InboxRepositoryOption(repository: "shilokuma-inc/ralph-kit", count: 1, displayName: "ralph-kit"),
            InboxRepositoryOption(repository: "shilokuma-inc/app", count: 2, displayName: "shilokuma-inc/app")
        ])
    }

    // MARK: - 絞り込み

    @Test func filtersByRepository() {
        let issues = [
            Self.issue("I_1", repository: "shilokuma-inc/app", updated: 300),
            Self.issue("I_2", repository: "mrs1669/app", updated: 200),
            Self.issue("I_3", repository: "shilokuma-inc/app", updated: 100)
        ]
        #expect(InboxRepositoryFilter.all.filtered(issues) == issues)
        #expect(Self.ids(InboxRepositoryFilter.repository("shilokuma-inc/app").filtered(issues)) == ["I_1", "I_3"])
        #expect(Self.ids(InboxRepositoryFilter.repository("mrs1669/app").filtered(issues)) == ["I_2"])
        #expect(InboxRepositoryFilter.repository("shilokuma-inc/other").filtered(issues).isEmpty)
    }

    @Test func resolvedFallsBackToAllWhenRepositoryIsGone() {
        let issues = [Self.issue("I_1", repository: "shilokuma-inc/app")]
        #expect(InboxRepositoryFilter.all.resolved(in: issues) == .all)
        #expect(InboxRepositoryFilter.repository("shilokuma-inc/app").resolved(in: issues) == .repository("shilokuma-inc/app"))
        #expect(InboxRepositoryFilter.repository("mrs1669/app").resolved(in: issues) == .all)
        #expect(InboxRepositoryFilter.repository("shilokuma-inc/app").resolved(in: []) == .all)
    }

    @Test func arrangedFiltersThenSorts() {
        let issues = [
            Self.issue("I_1", repository: "shilokuma-inc/app", created: 100, updated: 300),
            Self.issue("I_2", repository: "shilokuma-inc/ralph-kit", created: 200, updated: 400),
            Self.issue("I_3", repository: "shilokuma-inc/app", created: 300, updated: 100)
        ]
        #expect(Self.ids(issues.arranged(filter: .all, order: .default)) == ["I_2", "I_1", "I_3"])
        #expect(Self.ids(issues.arranged(filter: .repository("shilokuma-inc/app"), order: .createdNewest)) == ["I_3", "I_1"])
    }
}
