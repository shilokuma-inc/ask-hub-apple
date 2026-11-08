@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 最終 PR の確認とマージの承認を待つ epic（`reviewing`）の通知
extension NotifierTests {
    /// 最終 PR の段取りの epic（`FinalFlowFixture`）を、今の状態で知らせる
    func notify(_ given: FinalFlowFixture, with notifier: Notifier) async throws -> [PushNotice] {
        try await notifier.notify(epics: [given.epic()], jobs: given.jobs(), trusted: [deviceID])
    }

    /// 最終 PR の段取りの epic の、確認の待ちの出来事の key
    func reviewKey(head: String, review: JobFile) -> String {
        "review/\(FinalFlowFixture.repo)/\(FinalFlowFixture.epicID)/\(head)/\(review.id)"
    }

    /// 人が頼んだ直しが成功し、直した head（`head`）のレビューが通って、もう一度人の確認を待つところまで進める。そのレビューを返す
    func reviewAgain(_ given: FinalFlowFixture, after intent: IntentReference, head: String) async throws -> JobFile {
        let fix = try await given.job(FinalPullRequestState.humanFixID(intent))
        try await given.succeed(fix, outputs: .init(pullRequest: FinalFlowFixture.pullRequest, commit: head))
        let review = try await given.next(.reviewFinalPullRequest)
        try await given.succeed(review, outputs: .init(commit: head, verdict: .ready, mergeRisks: []))
        #expect(try await given.advance().created.isEmpty)
        #expect(try await given.epic().stage == .reviewing)
        return review
    }

    @Test func notifiesReviewingOnceAndAgainAfterHumanFixMovesHead() async throws {
        let given = FinalFlowFixture()
        try await putDevice(in: given.store)
        let sender = RecordingPushSender()
        let notifier = notifier(given.store, sender: sender)
        let review = try await given.reviewing()

        // 最終 PR のレビューが通り、見える仮決め（d1）への答えとマージの承認を待っている
        let notices = try await notify(given, with: notifier)
        #expect(notices.map(\.keys) == [[reviewKey(head: FinalFlowFixture.sha("a"), review: review)]])
        #expect(notices.first?.body == "最終 PR #512 のレビューが通りました。判断のカード 1 件に答えて、マージを承認してください")
        #expect(notices.first?.target == ["repo": FinalFlowFixture.repo.rawValue, "epic": FinalFlowFixture.epicID.rawValue])

        // カードに答えても、同じレビューの確認の待ちは知らせ直さない
        try await given.answer("d1", .ok)
        #expect(try await given.intake().processPending() == [.accepted(kind: "decision")])
        #expect(try await notify(given, with: notifier).isEmpty)
        // 人が頼んだ直しの間（finalizing）は、人を待っていない
        let intent = try await given.instruct("ボタンの文言を「保存」にして")
        #expect(try await given.intake().processPending() == [.accepted(kind: "instructFinal")])
        #expect(try await notify(given, with: notifier).isEmpty)

        // 直して head が変わり、もう一度レビューが通ったら、直した head の確認の待ちとして知らせ直す
        let again = try await reviewAgain(given, after: intent, head: FinalFlowFixture.sha("b"))
        let renotified = try await notify(given, with: notifier)
        #expect(renotified.map(\.keys) == [[reviewKey(head: FinalFlowFixture.sha("b"), review: again)]])
        #expect(renotified.first?.body == "最終 PR #512 の直しが済みました。確かめてマージを承認してください")
        #expect(await sender.sent.count == 2)
    }

    @Test func notifiesReviewingAgainAfterHumanFixThatKeepsHead() async throws {
        let given = FinalFlowFixture()
        try await putDevice(in: given.store)
        let notifier = notifier(given.store, sender: RecordingPushSender())
        _ = try await given.reviewing()
        #expect(try await notify(given, with: notifier).count == 1)

        // 直しで何も変えなくても、直させたカードは答え待ちに戻るので、新しいレビューの確認の待ちとして知らせ直す
        let intent = try await given.answer("d1", .fix, note: "見出しは 2 行にしてほしい")
        #expect(try await given.intake().processPending() == [.accepted(kind: "decision")])
        let again = try await reviewAgain(given, after: intent, head: FinalFlowFixture.sha("a"))
        let renotified = try await notify(given, with: notifier)
        #expect(renotified.map(\.keys) == [[reviewKey(head: FinalFlowFixture.sha("a"), review: again)]])
        #expect(renotified.first?.body == "最終 PR #512 の直しが済みました。判断のカード 1 件に答えて、マージを承認してください")
    }

    @Test func doesNotNotifyReviewingOnceMergeIsApproved() async throws {
        let given = FinalFlowFixture()
        try await putDevice(in: given.store)
        let sender = RecordingPushSender()
        _ = try await given.reviewing()
        try await given.answer("d1", .ok)
        try await given.approve()
        #expect(try await given.intake().processPending() == [.accepted(kind: "decision"), .accepted(kind: "approveMerge")])

        // 承認してマージが動いている間は、epic が reviewing のままでも、もう人を待っていない
        #expect(try await given.epic().stage == .reviewing)
        #expect(try await notify(given, with: notifier(given.store, sender: sender)).isEmpty)
        #expect(await sender.sent.isEmpty)
    }
}
