@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 実機確認の「問題あり」の添付（Discussion #669 のタスク 9）
@MainActor
struct VerifyProblemModelAttachmentTests {
    /// 上げる・依頼を作る・コメントするの順番を記録する
    nonisolated private final class Log: Sendable {
        private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])
        let commentFailures = OSAllocatedUnfairLock(initialState: 0)

        func append(_ entry: String) {
            entries.withLock { $0.append(entry) }
        }

        var all: [String] {
            entries.withLock { $0 }
        }
    }

    private struct Requester: IdeaRequesting {
        let log: Log

        func repositories(in orgs: [String]) async throws -> [RequestRepository] {
            []
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            log.append("create \(AttachmentMarker.parseAll(request.issueBody).map(\.name))")
            return CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/41")!)
        }

        func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
            throw IdeaRequestError.invalidRequest
        }
    }

    private struct Commenter: VerifyProblemCommenting {
        let log: Log

        func post(_ problem: VerifyProblem, request: CreatedIssue) async throws -> URL {
            let fails = log.commentFailures.withLock { count in
                defer { count = max(count - 1, 0) }
                return count > 0
            }
            if fails {
                throw GitHubError.http(status: 500, message: "boom")
            }
            log.append("comment \(AttachmentMarker.parseAll(problem.comment(request: request.number)).map(\.name))")
            return problem.issue.url
        }
    }

    private struct Uploader: AttachmentUploading {
        let log: Log
        var failure: (any Error & Sendable)?

        func upload(_ files: [AttachmentFile], to repository: String) async throws -> [AttachmentMarker] {
            log.append("upload \(repository) \(files.map(\.name))")
            if let failure {
                throw failure
            }
            return try await SampleAttachmentUploader().upload(files, to: repository)
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
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    private static let png = AttachmentFile(name: "crash.png", type: "image/png", data: Data([1, 2, 3]))

    private func makeModel(log: Log, uploadFailure: (any Error & Sendable)? = nil) -> VerifyProblemModel {
        let model = VerifyProblemModel(
            issue: Self.issue,
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeRequester: { _ in Requester(log: log) },
            makeCommenter: { _ in Commenter(log: log) },
            makeUploader: { _ in Uploader(log: log, failure: uploadFailure) }
        )
        model.description = "通知をタップしても開かない"
        model.attachments = [Self.png]
        return model
    }

    @Test func uploadsToIssueRepositoryThenRequestAndCommentHaveSameAttachments() async {
        let log = Log()
        let model = makeModel(log: log)
        await model.send()

        #expect(log.all == [
            "upload shilokuma-inc/ask-hub-apple [\"crash.png\"]",
            "create [\"crash.png\"]",
            "comment [\"crash.png\"]"
        ])
        #expect(model.isCompleted)
    }

    @Test func retryingCommentDoesNotUploadAgain() async {
        let log = Log()
        log.commentFailures.withLock { $0 = 1 }
        let model = makeModel(log: log)
        await model.send()
        #expect(model.isRetryingComment)
        #expect(model.confirmation == "再修正の依頼 #41 へのリンクを付けて、この Issue に問題の内容をコメントします。依頼は作り直しません")

        await model.send()
        #expect(log.all.filter { $0.hasPrefix("upload") }.count == 1)
        #expect(log.all.filter { $0.hasPrefix("create") }.count == 1)
        #expect(log.all.last == "comment [\"crash.png\"]")
        #expect(model.isCompleted)
    }

    @Test func postsNothingWhenUploadFails() async {
        let log = Log()
        let model = makeModel(log: log, uploadFailure: AttachmentUploadError.missingContentsPermission)
        await model.send()

        #expect(log.all == ["upload shilokuma-inc/ask-hub-apple [\"crash.png\"]"])
        #expect(model.createdRequest == nil)
        #expect(model.attachments == [Self.png])
        #expect(model.errorMessage
            == "添付を上げられませんでした。トークンに、依頼先のリポジトリの Contents の書き込み権限（Read and write）があるか確かめてください")
    }

    /// ドロップの受け口（Discussion #784）は、添付欄で添付を変えられる間だけ受け付ける
    @Test func attachmentsCanBeEditedOnlyBeforeRequestIsCreated() async {
        let log = Log()
        let model = makeModel(log: log)
        #expect(model.canEditAttachments)

        await model.send()
        // 送り終えたら添付欄を出さないので、ドロップも受け付けない
        #expect(model.isCompleted)
        #expect(!model.canEditAttachments)
    }

    @Test func attachmentsCannotBeEditedWhileRetryingComment() async {
        let log = Log()
        log.commentFailures.withLock { $0 = 1 }
        let model = makeModel(log: log)
        await model.send()

        // 依頼を作った後は、コメントの再試行で上げ直さないため変えさせない
        #expect(model.createdRequest != nil)
        #expect(!model.isCompleted)
        #expect(!model.canEditAttachments)
    }

    @Test func attachmentsCanStillBeEditedWhenUploadFails() async {
        let model = makeModel(log: Log(), uploadFailure: AttachmentUploadError.missingContentsPermission)
        await model.send()
        #expect(model.canEditAttachments)
    }

    @Test func confirmationMentionsAttachments() {
        let model = makeModel(log: Log())
        #expect(model.confirmation.hasPrefix("添付 1 件を shilokuma-inc/ask-hub-apple に上げてから、"))
    }
}
