@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 質問への回答の添付（Discussion #669 のタスク 7）
@MainActor
struct AnswerFormModelAttachmentTests {
    /// 上げる・投稿するの順番を記録する
    nonisolated private final class Log: Sendable {
        private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])

        func append(_ entry: String) {
            entries.withLock { $0.append(entry) }
        }

        var all: [String] {
            entries.withLock { $0 }
        }
    }

    private struct Poster: AnswerPosting {
        let log: Log

        func post(_ answer: Answer, to question: InboxQuestion) async throws -> URL {
            log.append("post \(answer.body)")
            return question.comment.url
        }
    }

    private struct Uploader: AttachmentUploading {
        let log: Log
        var failure: (any Error & Sendable)?

        func upload(_ files: [AttachmentFile], to repository: String) async throws -> [AttachmentMarker] {
            log.append("upload \(repository) \(files.map(\.name).joined(separator: ","))")
            if let failure {
                throw failure
            }
            return try await SampleAttachmentUploader().upload(files, to: repository)
        }
    }

    private static let png = AttachmentFile(name: "design.png", type: "image/png", data: Data([1, 2, 3]))

    private func makeInbox(log: Log, uploadFailure: (any Error & Sendable)? = nil) -> InboxModel {
        InboxModel(
            tokenStore: InMemoryTokenStore(token: "github_pat_saved"),
            makeSource: { _ in SampleInboxSource() },
            makePoster: { _ in Poster(log: log) },
            makeTrust: { _ in TrustedAuthors.default },
            makeUploader: { _ in Uploader(log: log, failure: uploadFailure) }
        )
    }

    private let question = SampleInboxSource.sampleQuestion

    @Test func uploadsToQuestionRepositoryThenPostsWithChoiceLineFirst() async throws {
        let log = Log()
        let inbox = makeInbox(log: log)
        let form = AnswerFormModel(question: question)
        form.choice = question.marker.options[0]
        form.note = "補足です"
        form.attachments = [Self.png]
        await form.post(using: inbox)

        #expect(log.all.count == 2)
        #expect(log.all.first == "upload \(question.subject.repository) design.png")
        let posted = try #require(log.all.last)
        #expect(posted.hasPrefix("post 回答: \(question.marker.options[0])\n補足です\n\n### 添付ファイル\n"))
        #expect(form.isPosted)
        #expect(form.attachments.isEmpty)
    }

    @Test func doesNotUploadWithoutAttachments() async {
        let log = Log()
        let form = AnswerFormModel(question: question)
        form.choice = question.marker.options[0]
        await form.post(using: makeInbox(log: log))
        #expect(log.all == ["post 回答: \(question.marker.options[0])"])
    }

    @Test func postsNothingAndKeepsAttachmentsWhenUploadFails() async {
        let log = Log()
        let form = AnswerFormModel(question: question)
        form.choice = question.marker.options[0]
        form.attachments = [Self.png]
        await form.post(using: makeInbox(log: log, uploadFailure: AttachmentUploadError.missingContentsPermission))

        #expect(log.all == ["upload \(question.subject.repository) design.png"])
        #expect(!form.isPosted)
        #expect(form.attachments == [Self.png])
        #expect(form.errorMessage
            == "添付を上げられませんでした。トークンに、依頼先のリポジトリの Contents の書き込み権限（Read and write）があるか確かめてください")
        #expect(form.errorMessage?.contains("github_pat_saved") == false)
    }

    @Test func attachmentsAloneCannotBePosted() {
        // 添付だけの回答は送れない（今の isValid のまま。仮決め）
        var freeForm = question
        freeForm.marker = QuestionMarker(id: "d12-q2")
        let form = AnswerFormModel(question: freeForm)
        form.attachments = [Self.png]
        #expect(!form.canPost)
    }
}
