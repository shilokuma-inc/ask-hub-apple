@testable import AskHub
import AskHubKit
import Foundation
import SwiftUI
import Testing

struct InboxIssueSectionsTests {
    private static func issue(_ id: String, _ kind: InboxIssue.Kind) -> InboxIssue {
        InboxIssue(
            id: id,
            kind: kind,
            repository: "o/r",
            number: 1,
            title: id,
            url: URL(string: "https://github.com/o/r/issues/1")!,
            author: "mrs1669",
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func groupsDecisionLogsBeforeNeedsVerifyKeepingOrder() {
        let issues = [
            Self.issue("V1", .needsVerify),
            Self.issue("D1", .decisionLog),
            Self.issue("V2", .needsVerify),
            Self.issue("D2", .decisionLog)
        ]

        let sections = InboxIssue.sections(of: issues)

        #expect(sections.map(\.header?.title) == ["判断ログ", "実機確認"])
        #expect(sections.map(\.header?.systemImage) == ["list.bullet.clipboard", "iphone"])
        // 見出しのアイコンは行のラベルと同じ種類の色
        #expect(sections.map(\.header?.tint) == [InboxIssue.Kind.decisionLog.color, InboxIssue.Kind.needsVerify.color])
        #expect(InboxIssue.Kind.decisionLog.color != InboxIssue.Kind.needsVerify.color)
        #expect(sections.map { $0.items.map(\.id) } == [["D1", "D2"], ["V1", "V2"]])
    }

    @Test func omitsKindWithoutIssues() {
        let sections = InboxIssue.sections(of: [Self.issue("V1", .needsVerify)])

        #expect(sections.map(\.header?.title) == ["実機確認"])
        #expect(sections.map { $0.items.map(\.id) } == [["V1"]])
    }

    @Test func noSectionsWithoutIssues() {
        #expect(InboxIssue.sections(of: []).isEmpty)
    }
}
