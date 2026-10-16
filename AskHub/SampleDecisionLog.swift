import AskHubKit
import Foundation

/// デモモード・Preview・UI テスト用。仮決め一覧のコメントの固定の履歴（処理済み・未処理の指示、ループの返信、信用外のコメント）
struct SampleDecisionLogComments: DecisionLogCommentsFetching {
    func comments(of issue: InboxIssue) async throws -> [IssueComment] {
        guard issue.id == "I_9" else {
            return []
        }
        let url = issue.url.absoluteString
        let start = issue.createdAt
        return [
            IssueComment(
                id: 1,
                author: "mrs1669",
                body: "#13 の「行の高さ」は別案 1（52pt）で",
                createdAt: start.addingTimeInterval(2 * 60 * 60),
                url: URL(string: "\(url)#issuecomment-1")
            ),
            IssueComment(
                id: 2,
                author: "mrs1669",
                body: "\(DecisionLogMarker.reply)\n#13 の行の高さを 52pt に変える修正タスクを追加しました。",
                createdAt: start.addingTimeInterval(3 * 60 * 60),
                url: URL(string: "\(url)#issuecomment-2")
            ),
            IssueComment(
                id: 3,
                author: "someone",
                body: "#14 は別案 1 でお願いします",
                createdAt: start.addingTimeInterval(4 * 60 * 60),
                url: URL(string: "\(url)#issuecomment-3")
            ),
            IssueComment(
                id: 4,
                author: "mrs1669",
                body: "#15 の「空の一覧の文言」について:\n「まだありません」にしたい",
                createdAt: start.addingTimeInterval(5 * 60 * 60),
                url: URL(string: "\(url)#issuecomment-4")
            )
        ]
    }
}
