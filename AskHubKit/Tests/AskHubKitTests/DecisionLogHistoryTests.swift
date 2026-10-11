@testable import AskHubKit
import Testing

struct DecisionLogHistoryTests {
    private static let trusted = TrustedAuthors(["mrs1669"])

    private static func comment(_ id: Int, _ author: String?, _ body: String) -> IssueComment {
        IssueComment(id: id, author: author, body: body)
    }

    @Test func classifiesCommentsAndMarksInstructionsBeforeLastReplyAsProcessed() {
        let comments = [
            Self.comment(1, "mrs1669", "#319 の「表の区切り」は別案 1（タブ区切り）で"),
            Self.comment(2, "mrs1669", "\(DecisionLogMarker.reply)\n#319 を変更しました"),
            Self.comment(3, "someone", "#319 は別案 2 で"),
            Self.comment(4, "MRS1669", "#320 の「余白」について:\n8pt に")
        ]
        let history = DecisionLogHistory(comments: comments, trustedAuthors: Self.trusted)

        #expect(history.entries.map(\.kind) == [.instruction(isProcessed: true), .reply, .untrusted, .instruction(isProcessed: false)])
        #expect(history.unprocessedInstructions == [comments[3]])
    }

    @Test func treatsCloseCommentAsMarker() {
        let comments = [
            Self.comment(1, "mrs1669", "#3 は別案 1 で"),
            Self.comment(2, "mrs1669", "\(DecisionLogMarker.close)\n閉じます")
        ]
        let history = DecisionLogHistory(comments: comments, trustedAuthors: Self.trusted)
        #expect(history.entries.map(\.kind) == [.instruction(isProcessed: true), .close])
        #expect(history.unprocessedInstructions.isEmpty)
    }

    @Test func ignoresMarkersWrittenByUntrustedAuthors() {
        let comments = [
            Self.comment(1, "mrs1669", "#3 は別案 1 で"),
            Self.comment(2, "someone", "\(DecisionLogMarker.reply)\n対応しました"),
            Self.comment(3, nil, "\(DecisionLogMarker.close)")
        ]
        let history = DecisionLogHistory(comments: comments, trustedAuthors: Self.trusted)
        #expect(history.entries.map(\.kind) == [.instruction(isProcessed: false), .untrusted, .untrusted])
        #expect(history.unprocessedInstructions == [comments[0]])
    }

    @Test func treatsAllTrustedCommentsAsUnprocessedWithoutReply() {
        let comments = [Self.comment(1, "mrs1669", "OK"), Self.comment(2, "mrs1669", "#3 は別案 1 で")]
        #expect(DecisionLogHistory.unprocessedInstructions(in: comments, trustedAuthors: Self.trusted) == comments)
        #expect(DecisionLogHistory(comments: [], trustedAuthors: Self.trusted).entries.isEmpty)
    }
}
