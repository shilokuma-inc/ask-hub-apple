@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import os
import Testing

/// リジェクトの直し方の案を、決めた案で返し、頼まれた材料を残す
final class FakeRejectionTriager: RejectionTriaging {
    let materials = OSAllocatedUnfairLock<[RejectionMaterial]>(initialState: [])
    let failure = OSAllocatedUnfairLock<ReleaseNotesFailure?>(initialState: nil)

    func triage(_ material: RejectionMaterial) async throws(ReleaseNotesFailure) -> RejectionProposal {
        materials.withLock { $0.append(material) }
        if let failure = failure.withLock({ $0 }) { throw failure }
        return RejectionProposal(
            remedy: .metadata,
            summary: "説明文に、まだ無いウィジェットの機能を書いていた（2.3.1）",
            plan: "説明文からウィジェットの文を外して、審査に出し直す",
            listing: [ListingText(locale: "ja", description: "推しの予定を数えるアプリ")],
            reply: "Thank you for your review. We removed the description of the widget."
        )
    }
}

/// リジェクトの理由を貼る・直し方を選ぶ人の意図（`ReportRejectionHandler`・`ResolveRejectionHandler`）
extension SubmissionHandlersTests {
    /// 審査に出して、iOS が断られた 1.2.0
    static func rejected() -> SubmissionFile {
        var file = prepared()
        let at = Timestamp(ReleaseWatchTests.now.addingTimeInterval(-3_600))
        file.submit = .init(
            approval: IntentReference(keyId: keyID, nonce: ULID(rawValue: "01JCN0NCE00000000000000005")!),
            at: at,
            builds: [.init(platform: .iOS, build: "45")],
            whatsNew: [.init(locale: "ja", text: "・ウィジェットを足しました")],
            releaseType: .afterApproval
        )
        file.review = [.init(platform: .iOS, state: .rejected, since: at, submittedAt: at)]
        return file
    }

    func rejectionEnvelope(_ kind: String, payload: [String: JSONValue], nonce: String) -> IntentEnvelope {
        IntentEnvelope(
            kind: kind,
            repo: ReleaseWatchTests.repo,
            target: .init(type: "submission", id: "1.2.0"),
            targetVersion: nil,
            payload: payload,
            issuedAt: Timestamp(ReleaseWatchTests.now),
            nonce: ULID(rawValue: nonce)!,
            keyId: Self.keyID
        )
    }

    @Test func recordsRejectionReportAndReplacesItBeforeChoice() async throws {
        var file = Self.prepared()
        try await put(file)
        let handler = ReportRejectionHandler()
        let text: [String: JSONValue] = ["text": .string("Guideline 2.3.1")]
        let report = rejectionEnvelope("reportRejection", payload: text, nonce: "01JCN0NCE0000000000000000A")
        // 断られていない版には貼れない
        #expect(try await handler.handle(report, in: context) == .reject("1.2.0 は審査で断られていない"))
        file = Self.rejected()
        try await put(file)
        #expect(try await handler.handle(report, in: context) == .accept)
        let recorded = try #require(try await self.file()?.rejection)
        #expect(recorded.submittedAt == file.submit?.at && recorded.platforms == [.iOS] && recorded.report.text == "Guideline 2.3.1")
        #expect(try await self.file()?.awaitsRejectionTriage == true)

        // 案を書いた後でも、選ぶ前なら貼り直せる（前の案は捨てる）
        var triaged = try #require(try await self.file())
        triaged.rejections?[0].triage = .init(remedy: .reply, summary: "誤解", plan: "返信する", reply: "Thanks", draftedAt: recorded.report.at)
        try await put(triaged)
        let again = rejectionEnvelope("reportRejection", payload: ["text": .string("Guideline 4.0")], nonce: "01JCN0NCE0000000000000000B")
        #expect(try await handler.handle(again, in: context) == .accept)
        let replaced = try #require(try await self.file())
        #expect(replaced.rejections?.count == 1)
        #expect(replaced.rejection?.report.text == "Guideline 4.0" && replaced.rejection?.triage == nil)
    }

    @Test func refusesRejectionReportWithMissingImage() async throws {
        try await put(Self.rejected())
        let data = Data("png".utf8)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let attachment = JSONValue.array([
            .object(["n": .integer(1), "name": .string("審査.png"), "size": .integer(Int64(data.count)), "sha256": .string(hash)])
        ])
        let report = rejectionEnvelope("reportRejection", payload: ["attachments": attachment], nonce: "01JCN0NCE0000000000000000C")
        // 画像を置く前は、記録を書かずに残す
        guard case .ignore = try await ReportRejectionHandler().handle(report, in: context) else {
            Issue.record("画像の無い理由を受け付けた")
            return
        }
        let path = StatePath.attachment(device: Self.keyID, nonce: ULID(rawValue: "01JCN0NCE0000000000000000C")!, number: 1)
        await store.put(path, data: data)
        #expect(try await ReportRejectionHandler().handle(report, in: context) == .accept)
        #expect(try await file()?.rejection?.report.attachments.map(\.name) == ["審査.png"])
    }

    @Test func resolvesMetadataAndPreparesResubmission() async throws {
        var file = Self.rejected()
        let report = SubmissionFile.RejectionReport(
            text: "Guideline 2.3.1",
            attachments: [],
            approval: IntentReference(keyId: Self.keyID, nonce: ULID(rawValue: "01JCN0NCE0000000000000000A")!),
            at: Timestamp(ReleaseWatchTests.now)
        )
        let rejectedListing = [ListingText(locale: "ja", description: "推しの予定を数え、ウィジェットにも出せるアプリ", keywords: "推し活")]
        let triage = SubmissionFile.RejectionTriage(
            remedy: .metadata,
            summary: "説明文に、まだ無い機能を書いていた",
            plan: "説明文を直して出し直す",
            listing: .init(
                current: rejectedListing,
                drafts: [.init(locale: "ja", description: "推しの予定を数えるアプリ")],
                reason: "説明文に、まだ無い機能を書いていた",
                draftedAt: report.at
            ),
            whatsNew: [.init(locale: "ja", text: "・予定の数え方を直しました")],
            draftedAt: report.at
        )
        file.rejections = [.init(submittedAt: file.submit!.at, platforms: [.iOS], report: report, triage: triage)]
        try await put(file)
        let handler = ResolveRejectionHandler()
        let resolve = rejectionEnvelope("resolveRejection", payload: ["remedy": .string("metadata")], nonce: "01JCN0NCE0000000000000000D")
        #expect(try await handler.handle(resolve, in: context) == .accept)
        let resolved = try #require(try await self.file())
        #expect(resolved.rejection?.choice?.remedy == .metadata)
        // 審査に出した中身を消し、出し直すシートの元を、断られた版の今の文と Claude の案にする
        #expect(resolved.submit == nil && resolved.revision == file.revision + 1)
        #expect(resolved.listing?.current == rejectedListing)
        #expect(resolved.listing?.drafts == [.init(locale: "ja", description: "推しの予定を数えるアプリ")])
        #expect(resolved.whatsNew?.drafts == [.init(locale: "ja", text: "・予定の数え方を直しました")])
        #expect(resolved.awaitsSubmission)
        // やり直しは受け付け、選び直しは断る
        #expect(try await handler.handle(resolve, in: context) == .accept)
        let other = rejectionEnvelope("resolveRejection", payload: ["remedy": .string("reply")], nonce: "01JCN0NCE0000000000000000E")
        #expect(try await handler.handle(other, in: context) == .reject("1.2.0 の直し方はもう選んだ"))
    }

    @Test func codeRemedyWaitsForBuildUploadedAfterChoice() async throws {
        var file = Self.rejected()
        let report = SubmissionFile.RejectionReport(
            text: "Guideline 2.1", attachments: [], approval: file.start!.approval, at: Timestamp(ReleaseWatchTests.now)
        )
        let triage = SubmissionFile.RejectionTriage(
            remedy: .code, summary: "起動で落ちる", plan: "落ちる所を直す", request: .init(title: "起動で落ちるのを直す", body: "…"), draftedAt: report.at
        )
        file.rejections = [.init(submittedAt: file.submit!.at, platforms: [.iOS], report: report, triage: triage)]
        try await put(file)
        let resolve = rejectionEnvelope("resolveRejection", payload: ["remedy": .string("code")], nonce: "01JCN0NCE0000000000000000D")
        #expect(try await ResolveRejectionHandler().handle(resolve, in: context) == .accept)
        var resolved = try #require(try await self.file())
        // 直した後に上げたビルドが見つかるまでは、出し直す準備はそろわない
        #expect(resolved.awaitsFixedBuild && !resolved.awaitsSubmission)
        // 前のビルドのままの what's new は、前に確かめた文
        #expect(resolved.whatsNew?.drafts == [.init(locale: "ja", text: "・ウィジェットを足しました")])
        resolved.builds = [.init(platform: .iOS, build: "46", uploadedAt: Timestamp(ReleaseWatchTests.now.addingTimeInterval(600)))]
        #expect(!resolved.awaitsFixedBuild && resolved.awaitsSubmission)
    }
}

/// リジェクトの直し方の案と、断られた提出の出し直し（`ReleaseWatch`）
extension ReleaseWatchTests {
    @Test func triagesReportedRejectionAndNotifies() async throws {
        var file = try await readyToSubmit()
        let submittedAt = file.submit!.at
        file.review = [.init(platform: .iOS, state: .rejected, since: submittedAt, submittedAt: submittedAt)]
        let report = SubmissionFile.RejectionReport(
            text: "Guideline 2.3.1", attachments: [], approval: file.start!.approval, at: submittedAt
        )
        file.rejections = [.init(submittedAt: submittedAt, platforms: [.iOS], report: report)]
        try await putSubmission(file)
        appStore.state.withLock { $0.others = [self.version(.rejected)] }
        let triager = FakeRejectionTriager()
        let watch = watch(rejections: triager)
        await watch.refresh()
        let triaged = try await submission()
        let triage = try #require(triaged.rejection?.triage)
        #expect(triage.remedy == .metadata && triage.summary.contains("2.3.1"))
        // 断られた版の今の掲載文を元に、直す欄だけを案にする
        #expect(triage.listing?.current.map(\.locale) == ["en-US", "ja"])
        #expect(triage.listing?.drafts == [.init(locale: "ja", description: "推しの予定を数えるアプリ")])
        let material = try #require(triager.materials.withLock { $0.first })
        #expect(material.text == "Guideline 2.3.1" && material.whatsNew.map(\.locale) == ["ja", "en-US"])
        #expect(material.commit == Self.developHead)
        #expect(triaged.awaitsRejectionChoice)
        let scope = Blocker.Scope.submission(Self.repo, Self.next)
        #expect(await watch.blockers.filter { $0.scope == scope }.map(\.reason).contains(.rejectionTriaged(failed: false)))
        // 案を書いたら、もう頼まない
        await watch.refresh()
        #expect(triager.materials.withLock { $0.count } == 1)
    }

    @Test func recordsTriageFailureThatWaitingCannotFix() async throws {
        var file = try await readyToSubmit()
        let submittedAt = file.submit!.at
        file.review = [.init(platform: .iOS, state: .rejected, since: submittedAt, submittedAt: submittedAt)]
        let report = SubmissionFile.RejectionReport(text: "Guideline 2.1", attachments: [], approval: file.start!.approval, at: submittedAt)
        file.rejections = [.init(submittedAt: submittedAt, platforms: [.iOS], report: report)]
        try await putSubmission(file)
        appStore.state.withLock { $0.others = [self.version(.rejected)] }
        let triager = FakeRejectionTriager()
        // 待てば書ける失敗は書かない
        triager.failure.withLock { $0 = ReleaseNotesFailure(message: "利用上限", retryable: true) }
        let watch = watch(rejections: triager)
        await watch.refresh()
        #expect(try await submission().rejection?.failure == nil)
        triager.failure.withLock { $0 = ReleaseNotesFailure(message: "形が合わない", retryable: false) }
        await watch.refresh()
        let failed = try await submission()
        #expect(failed.rejection?.failure?.contains("形が合わない") == true)
        #expect(failed.awaitsRejectionChoice)
        let scope = Blocker.Scope.submission(Self.repo, Self.next)
        #expect(await watch.blockers.filter { $0.scope == scope }.map(\.reason).contains(.rejectionTriaged(failed: true)))
    }

    @Test func notifiesRejectionAskingForReason() async throws {
        var file = try await readyToSubmit()
        let submittedAt = file.submit!.at
        file.review = [.init(platform: .iOS, state: .inReview, since: submittedAt, submittedAt: submittedAt)]
        try await putSubmission(file)
        appStore.state.withLock { $0.others = [self.version(.rejected)] }
        let watch = watch()
        await watch.refresh()
        let scope = Blocker.Scope.submission(Self.repo, Self.next)
        #expect(await watch.blockers.filter { $0.scope == scope }.map(\.reason).contains(.rejected(.iOS)))
        #expect(try await submission().awaitsRejectionReport)
    }

    @Test func resubmitsUnresolvedSubmissionAfterFix() async throws {
        var file = try await readyToSubmit()
        // 前の提出は 1 時間前に断られ、人が直し方を選んで出し直した（今の submit）
        let earlier = Timestamp(Self.now.addingTimeInterval(-3_600))
        file.review = [.init(platform: .iOS, state: .rejected, since: earlier, submittedAt: earlier)]
        try await putSubmission(file)
        appStore.state.withLock { state in
            state.others = [self.version(.rejected)]
            state.submissions = [AppStoreReviewSubmission(id: "s1", platform: .iOS, state: .unresolvedIssues, versionID: "v-1-2-0")]
        }
        await watch().refresh()
        let writes = appStore.state.withLock { $0.writes }
        #expect(writes.contains("resolveRejectedItems s1"))
        #expect(writes.last == "submitReviewSubmission s1")
        #expect(!writes.contains { $0.hasPrefix("createReviewSubmission") })
        let resubmitted = try await submission()
        #expect(resubmitted.review.first?.state == .waitingForReview && resubmitted.review.first?.submittedAt == file.submit?.at)
    }
}
