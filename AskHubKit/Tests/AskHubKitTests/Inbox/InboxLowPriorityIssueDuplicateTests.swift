@testable import AskHubKit
import Foundation
import Testing

/// 「任意判断」「実機確認」の取得で、search のページングで同じ Issue が 2 回来ても 1 つだけ出す
struct InboxLowPriorityIssueDuplicateTests {
    private func issue(_ id: String, kind: InboxIssue.Kind, repository: String = "o/r", updatedAt: TimeInterval) -> InboxIssue {
        InboxIssue(
            id: id,
            kind: kind,
            repository: repository,
            number: 1,
            title: id,
            url: URL(string: "https://github.com/\(repository)/issues/1")!,
            author: "mrs1669",
            createdAt: Date(timeIntervalSince1970: updatedAt),
            updatedAt: Date(timeIntervalSince1970: updatedAt)
        )
    }

    @Test func keepsFirstOfIssuesListedOnTwoPages() async throws {
        // 1 ページ目と 2 ページ目の両方に同じ Issue が出る（取得の途中で更新されて順位が動いた）
        let source = InboxFetcherTests.StubSource(issues: [
            issue("I_1", kind: .needsVerify, updatedAt: 3),
            issue("I_2", kind: .decisionLog, repository: "o/s", updatedAt: 2),
            issue("I_3", kind: .needsVerify, repository: "o/s", updatedAt: 1),
            issue("I_1", kind: .needsVerify, updatedAt: 4),
            issue("I_2", kind: .decisionLog, repository: "o/s", updatedAt: 2)
        ])
        let issues = try await InboxFetcher(source: source, trustedAuthors: TrustedAuthors(["mrs1669"])).lowPriorityIssues(orgs: ["o"])
        #expect(issues.map(\.id) == ["I_1", "I_2", "I_3"])
        #expect(issues[0].updatedAt == Date(timeIntervalSince1970: 3))

        // 絞り込み・並び替えの結果にも重複は残らない
        let verify = issues.filter { $0.kind == .needsVerify }
        for order in InboxIssueSortOrder.allCases {
            for filter in [InboxRepositoryFilter.all, .repository("o/r"), .repository("o/s")] {
                let arranged = verify.arranged(filter: filter, order: order)
                #expect(Set(arranged.map(\.id)).count == arranged.count)
            }
        }
        #expect(verify.arranged(filter: .all, order: .updatedOldest).map(\.id) == ["I_3", "I_1"])
        #expect(InboxRepositoryOption.options(in: verify).map(\.count) == [1, 1])
    }
}
