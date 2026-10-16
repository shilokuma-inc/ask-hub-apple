@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 任意判断の詳細画面の承認・指示（Discussion #349 の Q1〜Q3）
@MainActor
struct DecisionLogDetailModelTests {
    private static let body = """
        チェックを付けたものは承認。

        - [x] #12 並び順 → 採用: 新しい順
        - [ ] #14 間隔 → 採用: 5 分（別案: 1 分 / 15 分）
        - [ ] 形式に合わない行
        """

    private static let issue = InboxIssue(
        id: "I_9",
        kind: .decisionLog,
        repository: "o/r",
        number: 9,
        title: "【CHORE】epic/x の仮決め一覧",
        url: URL(string: "https://github.com/o/r/issues/9")!,
        author: "mrs1669",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        body: body
    )

    /// 承認を記録し、決めた結果を返す
    private final class RecordingApprover: DecisionApproving {
        let approved = OSAllocatedUnfairLock<[String]>(initialState: [])
        private let result: @Sendable (String, InboxIssue) throws -> DecisionApproval

        init(result: @escaping @Sendable (String, InboxIssue) throws -> DecisionApproval) {
            self.result = result
        }

        func approve(_ text: String, in issue: InboxIssue) async throws -> DecisionApproval {
            approved.withLock { $0.append(text) }
            return try result(text, issue)
        }

        /// 渡された本文に対して、実際の書き換えと同じくチェックを付ける
        static var checking: RecordingApprover {
            RecordingApprover { text, issue in
                switch DecisionLogCheck.check(text, in: issue.body) {
                case let .checked(body):
                    .approved(body: body)

                case .alreadyChecked:
                    .alreadyApproved(body: issue.body)

                case .notFound:
                    .notFound(body: issue.body)
                }
            }
        }
    }

    /// 投稿した指示の本文を記録する
    private final class RecordingPoster: DecisionInstructionPosting {
        let bodies = OSAllocatedUnfairLock<[String]>(initialState: [])
        private let failure: GitHubError?

        init(failure: GitHubError? = nil) {
            self.failure = failure
        }

        func post(_ instruction: DecisionInstruction, for item: DecisionLogItem, to issue: InboxIssue) async throws -> URL {
            if let failure {
                throw failure
            }
            bodies.withLock { $0.append(instruction.body(for: item) ?? "") }
            return URL(string: "https://github.com/o/r/issues/9#issuecomment-1")!
        }
    }

    private static func inbox(approver: RecordingApprover = .checking, poster: RecordingPoster = RecordingPoster()) -> InboxModel {
        InboxModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeSource: { _ in SampleInboxSource() },
            makeApprover: { _ in approver },
            makeInstructionPoster: { _ in poster },
            makeTrust: { _ in TrustedAuthors.default }
        )
    }

    private static var pending: DecisionLogItem {
        DecisionLogItem.items(in: body)[1]
    }

    @Test func readsItemsFromBody() {
        let model = DecisionLogDetailModel(issue: Self.issue)
        #expect(model.items.map(\.isChecked) == [true, false, false])
        #expect(model.items.map { $0.decision?.pullRequest } == [12, 14, nil])
    }

    @Test func approvalShowsRereadBody() async {
        let approver = RecordingApprover.checking
        let model = DecisionLogDetailModel(issue: Self.issue)
        await model.perform(.approve(Self.pending), using: Self.inbox(approver: approver))

        #expect(approver.approved.withLock { $0 } == ["#14 間隔 → 採用: 5 分（別案: 1 分 / 15 分）"])
        #expect(model.outcomes[Self.pending.text] == .approved)
        #expect(model.items.map(\.isChecked) == [true, true, false])
        #expect(!model.isSending)
    }

    @Test func missingLineShowsNoticeAndLatestBody() async {
        // ループが行を書き換えていたら承認せず、読み直した本文を出す
        let latest = "- [x] #14 間隔 → 採用: 5 分（別案: 1 分 / 15 分） → 変更: 別案 1（1 分）"
        let model = DecisionLogDetailModel(issue: Self.issue)
        await model.perform(.approve(Self.pending), using: Self.inbox(approver: RecordingApprover { _, _ in .notFound(body: latest) }))

        #expect(model.notice != nil)
        #expect(model.outcomes[Self.pending.text] == nil)
        #expect(model.items.map { $0.decision?.change } == ["別案 1（1 分）"])
    }

    @Test func alternativeIncludesNoteAndClearsIt() async {
        let poster = RecordingPoster()
        let model = DecisionLogDetailModel(issue: Self.issue)
        model.notes[Self.pending.text] = "  夜間は長めに  "
        await model.perform(.instruct(model.alternative(2, for: Self.pending), Self.pending), using: Self.inbox(poster: poster))

        #expect(poster.bodies.withLock { $0 } == ["#14 の「間隔」は別案 2（15 分）で\n夜間は長めに"])
        #expect(model.outcomes[Self.pending.text] == .instructed(URL(string: "https://github.com/o/r/issues/9#issuecomment-1")!))
        #expect(model.notes[Self.pending.text] == nil)
        #expect(model.postedInstructions == 1)
    }

    @Test func freeTextNeedsNote() {
        let model = DecisionLogDetailModel(issue: Self.issue)
        let malformed = model.items[2]
        #expect(!model.canSendFreeText(for: malformed))
        model.notes[malformed.text] = " \n "
        #expect(!model.canSendFreeText(for: malformed))
        model.notes[malformed.text] = "実機で見てから決める"
        #expect(model.canSendFreeText(for: malformed))
        #expect(model.confirmation(for: .instruct(.freeText(model.note(for: malformed)), malformed)).hasSuffix("> 形式に合わない行\n実機で見てから決める"))
    }

    @Test func permissionErrorIsShownOnItem() async {
        let model = DecisionLogDetailModel(issue: Self.issue)
        let poster = RecordingPoster(failure: .http(status: 403, message: "Resource not accessible by personal access token"))
        await model.perform(.instruct(.alternative(1, note: ""), Self.pending), using: Self.inbox(poster: poster))

        guard case let .failed(message) = model.outcomes[Self.pending.text] else {
            Issue.record("失敗が表示されない")
            return
        }
        #expect(message.contains("Issues の書き込み権限"))
        #expect(!message.contains("github_pat_saved"))
    }

    @Test func approvalUpdatesIssueInList() async {
        // 一覧の Issue の本文も読み直した本文にし、詳細画面を開き直しても古い本文に戻らないようにする
        let inbox = Self.inbox()
        await inbox.refresh()
        guard let issue = inbox.issues.first(where: { $0.kind == .decisionLog && $0.body.contains("#14 自動更新の間隔") }) else {
            Issue.record("サンプルに仮決め一覧が無い")
            return
        }
        let model = DecisionLogDetailModel(issue: issue)
        let item = model.items.first { $0.decision?.pullRequest == 14 }
        guard let item else {
            Issue.record("サンプルに #14 の項目が無い")
            return
        }
        await model.perform(.approve(item), using: inbox)
        #expect(inbox.issues.first { $0.id == issue.id }?.body.contains("- [x] #14 自動更新の間隔") == true)
    }
}
