@testable import AskHub
import AskHubKit
import Foundation
import os
import Testing

/// 依頼の送信での添付（Discussion #669 のタスク 4）
@MainActor
struct IdeaRequestModelAttachmentTests {
    /// 上げる・作るの順番を記録する
    nonisolated private final class Log: Sendable {
        private let entries = OSAllocatedUnfairLock<[String]>(initialState: [])

        func append(_ entry: String) {
            entries.withLock { $0.append(entry) }
        }

        var all: [String] {
            entries.withLock { $0 }
        }
    }

    private struct Requester: IdeaRequesting {
        let log: Log
        var failure: GitHubError?
        let created = OSAllocatedUnfairLock<[IdeaRequest]>(initialState: [])

        func repositories(in orgs: [String]) async throws -> [RequestRepository] {
            []
        }

        func create(_ request: IdeaRequest) async throws -> CreatedIssue {
            log.append("create \(request.repository)")
            if let failure {
                throw failure
            }
            created.withLock { $0.append(request) }
            return CreatedIssue(number: 41, htmlURL: URL(string: "https://github.com/\(request.repository)/issues/41")!)
        }

        func create(_ request: RepositoryRequest, in repository: String) async throws -> CreatedIssue {
            throw IdeaRequestError.invalidRequest
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
            return files.map { file in
                AttachmentMarker(
                    path: AttachmentMarker.path(id: UUID(), fileName: file.name),
                    sha: String(repeating: "b", count: 40),
                    commit: String(repeating: "c", count: 40),
                    name: file.name,
                    size: file.data.count,
                    type: file.type
                )
            }
        }
    }

    private static let png = AttachmentFile(name: "design.png", type: "image/png", data: Data([1, 2, 3]))
    private static let memo = AttachmentFile(name: "memo.md", type: "text/markdown", data: Data("# メモ".utf8))

    private func makeModel(
        log: Log,
        requester: Requester,
        uploadFailure: (any Error & Sendable)? = nil,
        token: String? = "github_pat_saved"
    ) -> IdeaRequestModel {
        let model = IdeaRequestModel(
            tokenStore: InMemoryTokenStore(token: token),
            makeRequester: { _ in requester },
            makeUploader: { _ in Uploader(log: log, failure: uploadFailure) }
        )
        model.repository = "shilokuma-inc/ask-hub-apple"
        model.summary = "画面を直したい"
        model.body = "デザインのとおりにしたい"
        return model
    }

    @Test func uploadsAttachmentsBeforeCreatingIssue() async throws {
        let log = Log()
        let requester = Requester(log: log)
        let model = makeModel(log: log, requester: requester)
        model.attachments = [Self.png, Self.memo]
        model.attachmentNotices = ["big.pdf は 10.0 MB を超えるため添付できません"]
        await model.send()

        #expect(log.all == [
            "upload shilokuma-inc/ask-hub-apple design.png,memo.md",
            "create shilokuma-inc/ask-hub-apple"
        ])
        let request = try #require(requester.created.withLock { $0.first })
        #expect(request.attachments.map(\.name) == ["design.png", "memo.md"])
        #expect(request.issueBody.hasPrefix("デザインのとおりにしたい\n\n### 添付ファイル\n"))
        #expect(AttachmentMarker.parseAll(request.issueBody).map(\.name) == ["design.png", "memo.md"])
        // 送れたら添付の一覧も、足さなかったファイルの説明も空にする
        #expect(model.attachments.isEmpty)
        #expect(model.attachmentNotices.isEmpty)
        #expect(model.body.isEmpty)
        #expect(model.errorMessage == nil)
        #expect(model.sent.count == 1)
    }

    @Test func doesNotUploadWithoutAttachments() async throws {
        let log = Log()
        let requester = Requester(log: log)
        let model = makeModel(log: log, requester: requester)
        await model.send()

        #expect(log.all == ["create shilokuma-inc/ask-hub-apple"])
        #expect(requester.created.withLock { $0.first?.issueBody } == "デザインのとおりにしたい")
    }

    @Test func createsNoIssueAndKeepsAttachmentsWhenUploadFails() async {
        let log = Log()
        let requester = Requester(log: log)
        let model = makeModel(log: log, requester: requester, uploadFailure: AttachmentUploadError.missingContentsPermission)
        model.attachments = [Self.png]
        model.attachmentNotices = ["big.pdf は 10.0 MB を超えるため添付できません"]
        await model.send()

        #expect(log.all == ["upload shilokuma-inc/ask-hub-apple design.png"])
        #expect(model.attachments == [Self.png])
        // 送れなかったときは、足さなかったファイルの説明も残す
        #expect(model.attachmentNotices == ["big.pdf は 10.0 MB を超えるため添付できません"])
        #expect(model.body == "デザインのとおりにしたい")
        #expect(model.sent.isEmpty)
        #expect(model.errorMessage
            == "添付を上げられませんでした。トークンに、依頼先のリポジトリの Contents の書き込み権限（Read and write）があるか確かめてください")
    }

    @Test func keepsInputAndUploadsAgainWhenIssueCreationFails() async {
        let log = Log()
        let model = makeModel(log: log, requester: Requester(log: log, failure: .http(status: 500, message: "boom")))
        model.attachments = [Self.png]
        await model.send()

        #expect(log.all == ["upload shilokuma-inc/ask-hub-apple design.png", "create shilokuma-inc/ask-hub-apple"])
        #expect(model.attachments == [Self.png])
        #expect(model.body == "デザインのとおりにしたい")
        #expect(model.sent.isEmpty)

        // もう一度送ると、添付を上げ直す（仮決め #683）
        await model.send()
        #expect(log.all.filter { $0.hasPrefix("upload") }.count == 2)
    }

    @Test func showsAttachmentCountInSentMessage() async {
        let log = Log()
        let model = makeModel(log: log, requester: Requester(log: log))
        model.attachments = [Self.png, Self.memo]
        await model.send()
        #expect(model.sent.first?.message == "ask-hub-apple に「画面を直したい」を依頼しました（添付 2 件）")
    }

    @Test(arguments: [
        AttachmentUploadError.missingContentsPermission as any Error & Sendable,
        AttachmentUploadError.conflict,
        GitHubError.rateLimited(retryAfter: .seconds(30)),
        GitHubError.http(status: 403, message: "Resource not accessible by personal access token")
    ])
    func uploadFailureMessageDoesNotContainToken(error: any Error & Sendable) async {
        let log = Log()
        let model = makeModel(log: log, requester: Requester(log: log), uploadFailure: error)
        model.attachments = [Self.png]
        await model.send()
        let message = model.errorMessage ?? ""
        #expect(!message.isEmpty)
        #expect(!message.contains("github_pat_saved"))
    }

    @Test func explainsConflictAndOtherFailuresWithoutToken() async {
        #expect(IdeaRequestModel.message(for: AttachmentUploadError.conflict) == "添付を上げられませんでした。少し待ってから、もう一度送ってください")

        let log = Log()
        let model = makeModel(
            log: log,
            requester: Requester(log: log),
            uploadFailure: GitHubError.http(status: 500, message: "boom")
        )
        model.attachments = [Self.png]
        await model.send()
        let message = model.errorMessage ?? ""
        #expect(message.contains("HTTP 500"))
        #expect(!message.contains("github_pat_saved"))
    }

    @Test func requiresTokenBeforeUploading() async {
        let log = Log()
        let model = makeModel(log: log, requester: Requester(log: log), token: nil)
        model.attachments = [Self.png]
        await model.send()

        #expect(log.all.isEmpty)
        #expect(model.errorMessage == "トークンが未設定です。設定で保存してください")
    }

    @Test func sampleModelUsesSampleUploader() async throws {
        // デモモード・サンプルでは GitHub に上げない（決まった blob SHA とコミットの目印になる）
        let model = IdeaRequestModel.sample()
        model.repository = "shilokuma-inc/ask-hub-apple"
        model.summary = "画面を直したい"
        model.body = "デザインのとおりにしたい"
        model.attachments = [Self.png]
        await model.send()

        #expect(model.errorMessage == nil)
        #expect(model.sent.count == 1)
        #expect(model.attachments.isEmpty)
        let markers = try await SampleAttachmentUploader().upload([Self.png], to: "o/r")
        let marker = try #require(markers.first)
        #expect(marker.sha == SampleAttachmentUploader.blob)
        #expect(marker.isWellFormed)
    }

    @Test func defaultModelUsesGitHubUploaderOnlyOutsideDemo() {
        // サンプルのモデルは GitHub の uploader を作らない
        let model = IdeaRequestModel.sample()
        #expect(model.makeUploader("sample") is SampleAttachmentUploader)
        #expect(IdeaRequestModel(tokenStore: InMemoryTokenStore()).makeUploader("t") is GitHubAttachmentUploader)
    }
}
