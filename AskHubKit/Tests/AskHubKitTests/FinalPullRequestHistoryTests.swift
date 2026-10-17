@testable import AskHubKit
import Testing

struct FinalPullRequestHistoryTests {
    private static let trusted = TrustedAuthors(["mrs1669"])

    private static func comment(_ id: Int, _ author: String?, _ body: String) -> IssueComment {
        IssueComment(id: id, author: author, body: body)
    }

    @Test func classifiesCommentsAndMarksInstructionsBeforeLastReplyAsProcessed() {
        let comments = [
            Self.comment(1, "mrs1669", "https://github.com/o/r/pull/12#discussion_r100 を直して"),
            Self.comment(2, "coderabbitai[bot]", "Actionable comments posted: 1"),
            Self.comment(3, "mrs1669", "\(FinalPullRequestMarker.reply)\n直しました"),
            Self.comment(4, "mrs1669", "\(FinalPullRequestMarker.orchestrator)\ndevelop を取り込みました"),
            Self.comment(5, "MRS1669", "https://github.com/o/r/pull/12#discussion_r200 も直して")
        ]
        let history = FinalPullRequestHistory(comments: comments, trustedAuthors: Self.trusted)

        #expect(history.entries.map(\.kind) == [
            .instruction(isProcessed: true), .untrusted, .reply, .orchestrator, .instruction(isProcessed: false)
        ])
        #expect(history.unprocessedInstructions == [comments[4]])
    }

    @Test func doesNotTreatOrchestratorCommentAsInstructionOrReply() {
        let comments = [
            Self.comment(1, "mrs1669", "#discussion_r100 を直して"),
            Self.comment(2, "mrs1669", "\(FinalPullRequestMarker.orchestrator)\nコンフリクトを解消しました")
        ]
        let history = FinalPullRequestHistory(comments: comments, trustedAuthors: Self.trusted)
        #expect(history.entries.map(\.kind) == [.instruction(isProcessed: false), .orchestrator])
        #expect(history.unprocessedInstructions == [comments[0]])
    }

    @Test func doesNotTreatLegacyOrchestratorCommentsOrCodeRabbitCommandsAsInstructions() {
        let comments = [
            Self.comment(1, "mrs1669", "develop を epic/mvp に取り込みました。\nCI が通ってからマージしてください。（askhub-orchestrator）\n"),
            Self.comment(2, "mrs1669", "@coderabbitai review"),
            Self.comment(3, "mrs1669", "  @CodeRabbitAI full review"),
            Self.comment(4, "mrs1669", "#discussion_r100 を直して（@coderabbitai の指摘）"),
            // CodeRabbit 宛ての書き出しでも、指摘を指していれば指示
            Self.comment(5, "mrs1669", "@coderabbitai の指摘 #discussion_r200 を直して")
        ]
        let history = FinalPullRequestHistory(comments: comments, trustedAuthors: Self.trusted)
        #expect(history.entries.map(\.kind) == [
            .orchestrator, .codeRabbitCommand, .codeRabbitCommand, .instruction(isProcessed: false), .instruction(isProcessed: false)
        ])
        #expect(history.unprocessedInstructions == [comments[3], comments[4]])
    }

    @Test func ignoresMarkersWrittenByUntrustedAuthors() {
        let comments = [
            Self.comment(1, "mrs1669", "#discussion_r100 を直して"),
            Self.comment(2, "someone", "\(FinalPullRequestMarker.reply)\n直しました"),
            Self.comment(3, nil, FinalPullRequestMarker.reply)
        ]
        let history = FinalPullRequestHistory(comments: comments, trustedAuthors: Self.trusted)
        #expect(history.entries.map(\.kind) == [.instruction(isProcessed: false), .untrusted, .untrusted])
        #expect(history.unprocessedInstructions == [comments[0]])
    }

    @Test func readsMarkerOnlyAtTheBeginningOfBody() {
        let comments = [
            Self.comment(1, "mrs1669", "直して"),
            Self.comment(2, "mrs1669", "\n  \(FinalPullRequestMarker.reply)\n直しました"),
            // 指示が引用した指摘の中に目印があっても、指示のまま扱う
            Self.comment(3, "mrs1669", "#discussion_r100 を直して\n> \(FinalPullRequestMarker.reply)"),
            Self.comment(4, "mrs1669", "#discussion_r200 を直して\n> \(FinalPullRequestMarker.orchestrator)")
        ]
        let history = FinalPullRequestHistory(comments: comments, trustedAuthors: Self.trusted)
        #expect(history.entries.map(\.kind) == [
            .instruction(isProcessed: true), .reply, .instruction(isProcessed: false), .instruction(isProcessed: false)
        ])
        #expect(history.unprocessedInstructions == [comments[2], comments[3]])
    }

    @Test func doesNotTreatDecisionLogMarkersAsReplies() {
        let comments = [Self.comment(1, "mrs1669", "\(DecisionLogMarker.reply)\n直して")]
        #expect(FinalPullRequestHistory.unprocessedInstructions(in: comments, trustedAuthors: Self.trusted) == comments)
    }

    @Test func treatsAllTrustedCommentsAsUnprocessedWithoutReply() {
        let comments = [Self.comment(1, "mrs1669", "OK"), Self.comment(2, "mrs1669", "#discussion_r1 を直して")]
        #expect(FinalPullRequestHistory.unprocessedInstructions(in: comments, trustedAuthors: Self.trusted) == comments)
        #expect(FinalPullRequestHistory(comments: [], trustedAuthors: Self.trusted).entries.isEmpty)
    }

    @Test func readsReferencedReviewCommentsInOrderWithoutDuplicates() {
        let body = """
            https://github.com/o/r/pull/12#discussion_r2412345678 を直して
            > 引用（https://github.com/o/r/pull/12#discussion_r99 と #discussion_r2412345678）
            """
        #expect(FinalPullRequestHistory.referencedReviewComments(in: body) == [2_412_345_678, 99])
    }

    @Test func readsReviewCommentLinksFromFilesChangedTab() {
        let body = "https://github.com/o/r/pull/12/files#r2412345678 と #discussion_r2412345678 を直して"
        #expect(FinalPullRequestHistory.referencedReviewComments(in: body) == [2_412_345_678])
    }

    @Test func readsNoReviewCommentsWithoutAnchor() {
        #expect(FinalPullRequestHistory.referencedReviewComments(in: "README の誤字を直して").isEmpty)
        #expect(FinalPullRequestHistory.referencedReviewComments(in: "#discussion_r を直して").isEmpty)
        #expect(FinalPullRequestHistory.referencedReviewComments(in: "#issuecomment-123 を見て").isEmpty)
        #expect(FinalPullRequestHistory.referencedReviewComments(in: "README の #readme と #r12abc を見て").isEmpty)
    }
}
