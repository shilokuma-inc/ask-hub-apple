import AskHubKit
@testable import OrchestratorKit
import Testing

struct DecisionLogTests {
    private static func issue(title: String, body: String = "") -> DecisionLogIssue {
        DecisionLogIssue(repository: "shilokuma-inc/ask-hub-apple", number: 9, title: title, body: body)
    }

    @Test func readsEpicBranchFromTitle() {
        #expect(Self.issue(title: "【CHORE】epic/mvp の仮決め一覧").branch == "epic/mvp")
        #expect(Self.issue(title: "【CHORE】epic/icon-and-repo-picker の仮決め一覧").branch == "epic/icon-and-repo-picker")
        // epic 以外のブランチ・形式の違うタイトルは epic と対応づけない
        #expect(Self.issue(title: "【CHORE】feat/x の仮決め一覧").branch == nil)
        #expect(Self.issue(title: "epic/mvp の仮決め一覧").branch == nil)
        #expect(Self.issue(title: "【CHORE】epic/mvp の仮決め一覧（旧）").branch == nil)
    }

    @Test func listsUncheckedItemsOnly() {
        let body = """
            チェックを付けたものは承認。

            - [x] #3 色 → 採用: 青
            - [ ] #4 文言 → 採用: 「保存」（別案: 「完了」）
              - [ ] #5 余白 → 採用: 16pt
            """
        #expect(DecisionLog.uncheckedItems(in: body) == ["#4 文言 → 採用: 「保存」（別案: 「完了」）", "#5 余白 → 採用: 16pt"])
        #expect(DecisionLog.uncheckedItems(in: "- [x] #3 色").isEmpty)
    }

    @Test func treatsTrustedCommentsAfterLastReplyAsUnprocessed() {
        let trusted = TrustedAuthors(["mrs1669"])
        let instruction = IssueComment(id: 1, author: "mrs1669", body: "#4 は別案 1 で")
        let reply = IssueComment(id: 2, author: "mrs1669", body: "\(DecisionLog.replyMarker)\n#4 を変更しました")
        let next = IssueComment(id: 3, author: "MRS1669", body: "#5 は 8pt に")
        let untrusted = IssueComment(id: 4, author: "someone", body: "#4 は別案 2 で")

        #expect(DecisionLog.unprocessedInstructions(in: [instruction], trustedAuthors: trusted) == [instruction])
        // ループが返信済みなら未処理は無い。返信より後のコメントだけが未処理
        #expect(DecisionLog.unprocessedInstructions(in: [instruction, reply], trustedAuthors: trusted).isEmpty)
        #expect(DecisionLog.unprocessedInstructions(in: [instruction, reply, next], trustedAuthors: trusted) == [next])
        // 信用する author 以外のコメントは指示として扱わない
        #expect(DecisionLog.unprocessedInstructions(in: [reply, untrusted], trustedAuthors: trusted).isEmpty)
        #expect(DecisionLog.unprocessedInstructions(in: [], trustedAuthors: trusted).isEmpty)
    }

    @Test func closingCommentListsItemsConfirmedByDefault() {
        let confirmed = DecisionLog.closingComment(pullRequest: 61, uncheckedItems: [])
        #expect(confirmed.hasPrefix(DecisionLog.closeMarker))
        #expect(confirmed.contains("epic の最終 PR #61 がマージされたので"))
        #expect(confirmed.contains("すべての仮決めが確認済みです。"))

        let partial = DecisionLog.closingComment(pullRequest: 61, uncheckedItems: ["#4 文言 → 採用: 「保存」"])
        #expect(partial.contains("次の 1 件は返答が無かったため、既定値のまま確定しました。\n- #4 文言 → 採用: 「保存」"))
        #expect(partial.contains("Issue か AskHub の依頼から出してください"))
    }
}
