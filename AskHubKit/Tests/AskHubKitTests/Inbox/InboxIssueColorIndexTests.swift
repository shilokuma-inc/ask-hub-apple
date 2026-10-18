@testable import AskHubKit
import Foundation
import Testing

struct InboxIssueColorIndexTests {
    private static func issue(repository: String, number: Int = 18) -> InboxIssue {
        InboxIssue(
            id: "I_\(number)",
            kind: .needsVerify,
            repository: repository,
            number: number,
            title: "【CHORE】実機確認: 通知の表示",
            url: URL(string: "https://github.com/\(repository)/issues/\(number)")!,
            author: "mrs1669",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    @Test func colorIndexComesFromRepositoryOnly() {
        #expect(InboxIssue.colorIndex(repository: "shilokuma-inc/ask-hub-apple", paletteCount: 6) == 2)
        #expect(InboxIssue.colorIndex(repository: "shilokuma-inc/ralph-kit", paletteCount: 6) == 0)
        // 番号や種類が違っても、同じリポジトリなら同じ色
        #expect(Self.issue(repository: "shilokuma-inc/ask-hub-apple").repositoryColorIndex(paletteCount: 6) == 2)
        var decision = Self.issue(repository: "shilokuma-inc/ask-hub-apple", number: 99)
        decision.kind = .decisionLog
        #expect(decision.repositoryColorIndex(paletteCount: 6) == 2)
    }

    @Test func colorIndexIgnoresCase() {
        // GitHub のリポジトリ名は大文字小文字を区別しない
        #expect(InboxIssue.colorIndex(repository: "Shilokuma-Inc/Ask-Hub-Apple", paletteCount: 6) == 2)
    }

    @Test func colorIndexStaysInPalette() {
        let indices = (0..<50).compactMap { InboxIssue.colorIndex(repository: "owner/repo\($0)", paletteCount: 6) }
        #expect(indices.count == 50)
        #expect(indices.allSatisfy { (0..<6).contains($0) })
        // 偏って 1 色に寄らない
        #expect(Set(indices).count == 6)
        #expect(InboxIssue.colorIndex(repository: "shilokuma-inc/ask-hub-apple", paletteCount: 0) == nil)
        #expect(Self.issue(repository: "shilokuma-inc/ask-hub-apple").repositoryColorIndex(paletteCount: -1) == nil)
    }
}
