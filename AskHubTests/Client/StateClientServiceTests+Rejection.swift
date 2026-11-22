@testable import AskHub
import AskHubClient
import AskHubKit
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// リジェクト: 断られた版に理由（文と画像）を貼り、Claude の直し方の案を出し、人が選んだ直し方を送る
extension StateClientServiceTests {
    /// 1.2.0 を審査に出して iOS が断られた。`rejection` があれば、その対処も書く
    private static func rejectedFiles(rejection: SubmissionFile.Rejection? = nil) throws -> [String: String] {
        let path = "repos/\(repo)/submissions/1.2.0.json"
        let ready = try #require(submissionFiles()[path])
        var file = try StateFileCoder.decode(SubmissionFile.self, from: Data(ready.utf8))
        let at = Timestamp(rawValue: "2027-01-20T02:00:00Z")!
        file.submit = .init(
            approval: file.start!.approval,
            at: at,
            builds: [.init(platform: .iOS, build: "45")],
            whatsNew: [.init(locale: "ja", text: "・速くなりました"), .init(locale: "en-US", text: "- Faster")],
            releaseType: .afterApproval
        )
        file.review = [.init(platform: .iOS, state: .rejected, since: Timestamp(rawValue: "2027-01-21T02:00:00Z")!, submittedAt: at)]
        if var rejection {
            rejection.submittedAt = at
            file.rejections = [rejection]
        }
        let data = try StateFileCoder.encode(file)
        let text = try #require(String(bytes: data, encoding: .utf8))
        return submissionFiles(extra: [path: text])
    }

    private var rejectedID: Submission.ID { Submission.id(Self.repo.lowercased(), "1.2.0") }

    @Test
    func rejectedReleaseAsksForReasonAndSendsImagesFirst() async throws {
        let fixture = try makeService(files: try Self.rejectedFiles())
        let snapshot = try await fixture.service.fetchSnapshot()
        let submission = try #require(snapshot.submission(rejectedID))
        #expect(submission.isRejected && submission.awaitsRejectionReport && submission.canReportRejection)
        // あなたの番には、理由を貼るよう出す
        let items = InboxBuilder.submissionItems(submission, snapshot: snapshot)
        #expect(items.map(\.title) == ["審査で断られました"])
        #expect(items.first?.detail.contains("AskHub に貼ってください") == true)

        let image = AttachmentFile(name: "審査の文.png", type: "image/png", data: Data([0x89, 0x50, 0x4E, 0x47]))
        let files = try RequestFile.make([image]).get()
        let intent = HumanIntent.reportRejection(
            repositoryID: Self.repo.lowercased(), version: "1.2.0", text: " Guideline 2.3.1 ", images: files
        )
        #expect(fixture.service.supports(intent))
        try await fixture.service.perform(intent)
        let envelope = try await sentEnvelope(in: fixture.store, key: fixture.key)
        let report = try ReportRejectionIntent(envelope: envelope)
        #expect(report.text == "Guideline 2.3.1" && report.attachments.map(\.name) == ["審査の文.png"])
        let path = StatePath.attachment(device: fixture.key.keyID, nonce: envelope.nonce, number: 1)
        #expect(await fixture.store.data(at: path) == image.data)
        // 受け付けを待っている間は送れない
        #expect(try await fixture.service.fetchSnapshot().submission(rejectedID)?.sending == .reportRejection)
        #expect(!fixture.service.supports(intent))
    }

    @Test
    func showsTriageAndSendsChosenRemedy() async throws {
        let report = SubmissionFile.RejectionReport(
            text: "Guideline 2.3.1",
            attachments: [RequestAttachment(number: 1, name: "審査.png", contents: Data("png".utf8))!],
            approval: IntentReference(
                keyId: KeyID(rawValue: String(repeating: "k", count: 43))!, nonce: ULID(rawValue: "01JCN0NCE0000000000000000A")!
            ),
            at: Timestamp(rawValue: "2027-01-21T03:00:00Z")!
        )
        let triage = SubmissionFile.RejectionTriage(
            remedy: .metadata,
            summary: "説明文に、まだ無い機能を書いていた",
            plan: "説明文を直して出し直す",
            listing: .init(
                current: [.init(locale: "ja", description: "素数のクイズ。Apple Watch でも", keywords: "素数,クイズ")],
                drafts: [.init(locale: "ja", description: "素数のクイズ")],
                reason: "説明文に、まだ無い機能を書いていた",
                draftedAt: report.at
            ),
            reply: "Thank you.",
            draftedAt: report.at
        )
        let rejection = SubmissionFile.Rejection(
            submittedAt: report.at, platforms: [.iOS], report: report, triage: triage
        )
        let fixture = try makeService(files: try Self.rejectedFiles(rejection: rejection))
        let snapshot = try await fixture.service.fetchSnapshot()
        let submission = try #require(snapshot.submission(rejectedID))
        let shown = try #require(submission.rejection)
        #expect(shown.triage?.remedy == .metadata && shown.triage?.reply == "Thank you.")
        #expect(shown.triage?.metadataChanges == ["説明文（ja）"])
        #expect(shown.images.map(\.name) == ["審査.png"])
        #expect(shown.images.first?.path.hasSuffix("/01JCN0NCE0000000000000000A/1") == true)
        #expect(submission.awaitsRejectionChoice)
        #expect(InboxBuilder.submissionItems(submission, snapshot: snapshot).map(\.title) == ["リジェクトの直し方を選ぶ"])

        let intent = HumanIntent.resolveRejection(repositoryID: Self.repo.lowercased(), version: "1.2.0", remedy: .reply)
        #expect(fixture.service.supports(intent))
        try await fixture.service.perform(intent)
        let resolve = try ResolveRejectionIntent(envelope: try await sentEnvelope(in: fixture.store, key: fixture.key))
        #expect(resolve.remedy == .reply)
        #expect(!fixture.service.supports(intent))
    }
}
