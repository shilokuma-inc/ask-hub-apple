@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 実機確認の「問題あり」（Issue #483）
@MainActor
struct VerifyProblemModelTests {
    /// 作った依頼を記録する。`failure` を渡すと失敗する
    private final class RecordingRequester: IdeaRequesting {
        private let created = OSAllocatedUnfairLock<[IdeaRequest]>(initialState: [])
        private let failure: GitHubError?

        init(failure: GitHubError? = nil) {
            self.failure = failure
        }

        var requests: [IdeaRequest] {
            created.withLock { $0 }
        }

        func repositories(in orgs: [String]) async throws -> [RequestRepository] {
            []
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            if let failure {
                throw failure
            }
            created.withLock { $0.append(request) }
            return CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/41")!)
        }

        func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
            Issue.record("作成・削除の依頼は作らない")
            return CreatedIssue(number: 0, htmlURL: URL(string: "https://github.com/\(repository)/issues/0")!)
        }
    }

    /// 投稿したコメント（`<依頼の番号> <本文>`）を記録する。`failures` の数だけ先に失敗する
    private final class RecordingCommenter: VerifyProblemCommenting {
        private let posted = OSAllocatedUnfairLock<[String]>(initialState: [])
        private let failures: OSAllocatedUnfairLock<[GitHubError]>

        init(failures: [GitHubError] = []) {
            self.failures = OSAllocatedUnfairLock(initialState: failures)
        }

        var comments: [String] {
            posted.withLock { $0 }
        }

        func post(_ problem: VerifyProblem, request: CreatedIssue) async throws -> URL {
            if let failure = failures.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
                throw failure
            }
            posted.withLock { $0.append("#\(request.number) \(problem.comment(request: request.number))") }
            return problem.issue.url
        }
    }

    private static let issue = InboxIssue(
        id: "I_18",
        kind: .needsVerify,
        repository: "shilokuma-inc/ask-hub-apple",
        number: 18,
        title: "【CHORE】実機確認: 通知の表示",
        url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/18")!,
        author: "mrs1669",
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0),
        body: VerifyMarker(pullRequest: 17, epic: "epic/mvp").marker + "\n## 確認手順"
    )

    private func makeModel(
        token: String? = "github_pat_saved",
        requester: RecordingRequester,
        commenter: RecordingCommenter
    ) -> VerifyProblemModel {
        VerifyProblemModel(
            issue: Self.issue,
            tokenStore: InMemoryTokenStore(token: token),
            makeRequester: { _ in requester },
            makeCommenter: { _ in commenter }
        )
    }

    @Test func createsRequestThenComments() async {
        let requester = RecordingRequester()
        let commenter = RecordingCommenter()
        let model = makeModel(requester: requester, commenter: commenter)
        model.description = "通知をタップしても開かない"
        await model.send()

        #expect(requester.requests.map(\.title) == ["【依頼】実機確認の問題: 通知の表示"])
        #expect(requester.requests.first?.repository == "shilokuma-inc/ask-hub-apple")
        #expect(requester.requests.first?.body == """
        実機確認 Issue: https://github.com/shilokuma-inc/ask-hub-apple/issues/18
        元の PR: #17
        epic: epic/mvp

        通知をタップしても開かない
        """)
        #expect(commenter.comments == ["#41 <!-- ask-hub:verify-problem -->\n通知をタップしても開かない\n\n再修正の依頼: #41"])
        #expect(model.isCompleted)
        #expect(model.createdRequest?.number == 41)
        #expect(model.errorMessage == nil)
        #expect(!model.canSend)
    }

    @Test func requiresDescription() async {
        let requester = RecordingRequester()
        let commenter = RecordingCommenter()
        let model = makeModel(requester: requester, commenter: commenter)
        model.description = " \n "
        #expect(!model.canSend)
        await model.send()

        #expect(requester.requests.isEmpty)
        #expect(commenter.comments.isEmpty)
    }

    @Test func postsNothingWhenRequestFails() async {
        let commenter = RecordingCommenter()
        let model = makeModel(requester: RecordingRequester(failure: .http(status: 403, message: "Forbidden")), commenter: commenter)
        model.description = "落ちる"
        await model.send()

        #expect(commenter.comments.isEmpty)
        #expect(model.createdRequest == nil)
        #expect(!model.isCompleted)
        #expect(model.errorMessage == "送れませんでした。トークンに、このリポジトリの Issues の書き込み権限（Read and write）があるか確かめてください")
        #expect(model.canSend)
    }

    @Test func retriesOnlyCommentAfterCommentFails() async {
        let requester = RecordingRequester()
        let commenter = RecordingCommenter(failures: [.http(status: 404, message: "Not Found")])
        let model = makeModel(requester: requester, commenter: commenter)
        model.description = "落ちる"
        await model.send()

        #expect(requester.requests.count == 1)
        #expect(commenter.comments.isEmpty)
        #expect(model.isRetryingComment)
        #expect(model.errorMessage?.hasPrefix("再修正の依頼 #41 は作りましたが、この Issue へのコメントを投稿できませんでした。") == true)

        // 再試行では依頼を作り直さず、依頼を作ったときの内容でコメントする
        model.description = "書き換えた内容"
        await model.send()
        #expect(requester.requests.count == 1)
        #expect(commenter.comments == ["#41 <!-- ask-hub:verify-problem -->\n落ちる\n\n再修正の依頼: #41"])
        #expect(model.isCompleted)
        #expect(!model.isRetryingComment)
    }

    @Test func requiresTokenAndHidesItInMessage() async {
        let requester = RecordingRequester()
        let model = makeModel(token: nil, requester: requester, commenter: RecordingCommenter())
        model.description = "落ちる"
        await model.send()
        #expect(requester.requests.isEmpty)
        #expect(model.errorMessage == "送れませんでした。トークンが未設定です。設定で保存してください")

        let failing = makeModel(
            requester: RecordingRequester(failure: .http(status: 500, message: "boom")),
            commenter: RecordingCommenter()
        )
        failing.description = "落ちる"
        await failing.send()
        #expect(failing.errorMessage?.contains("github_pat_saved") == false)
    }

    @Test func sampleModelDoesNotUseGitHub() async {
        // デモモード・サンプルの依頼モデルから作ると、GitHub に書き込まないサンプルの依頼とコメントになる
        let model = IdeaRequestModel.sample().verifyProblemModel(for: Self.issue)
        model.description = "落ちる"
        await model.send()
        #expect(model.isCompleted)
        #expect(model.createdRequest?.number == 41)
    }
}
