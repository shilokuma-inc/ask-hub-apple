@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 最終 PR への人の意図（判断のカードへの答え・マージの承認・最終 PR への指示）の受け付け
struct FinalPullRequestHandlersTests {
    typealias Fixture = FinalFlowFixture
    let given = Fixture()

    private func process() async throws -> [IntakeOutcome] {
        try await given.intake().processPending()
    }

    // MARK: - 判断のカード

    @Test func decisionOkWritesAnswerOnly() async throws {
        let review = try await given.reviewing()
        let intent = try await given.answer("d1", .ok)
        #expect(try await process() == [.accepted(kind: "decision")])
        let answer = try #require(try await given.decisions().items.first?.answer)
        #expect(answer.choice == .ok)
        #expect(answer.intent == intent)
        #expect(answer.at == Timestamp(Fixture.now))
        // OK は直させない。人の確認の待ちのまま
        #expect(try await !given.jobs().contains { $0.dependsOn.contains(review.id) })
        #expect(try await given.epic().stage == .reviewing)
    }

    @Test func decisionFixStartsHumanFixAndReopensCardAfterFix() async throws {
        let review = try await given.reviewing()
        let intent = try await given.answer("d1", .fix, note: "見出しは 2 行にしてほしい")
        #expect(try await process() == [.accepted(kind: "decision")])
        #expect(try await given.decisions().items.first?.answer?.choice == .fix)
        // 人の文で直させる直し（元の人の意図はこの答え）を作り、レビューからやり直すので finalizing に戻す
        let fix = try await given.job(FinalPullRequestState.humanFixID(intent))
        #expect(fix.kind == .fixFinalPullRequest)
        #expect(fix.origin == intent)
        #expect(fix.dependsOn == [review.id])
        #expect(fix.assignedMac == Fixture.laptop)
        #expect(fix.input(as: FixTaskInput.self) == FixTaskInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("a"), reason: .human))
        #expect(try await given.epic().stage == .finalizing)
        // 直しを待つ間は何も作らない
        #expect(try await given.advance().created.isEmpty)

        // 直した: 答えを外して答え待ちに戻し、直した head でレビューする
        let report = TaskOutputReport(summary: "2 行にした")
        try await given.succeed(fix, outputs: .init(pullRequest: Fixture.pullRequest, commit: Fixture.sha("b"), report: report))
        let again = try await given.next(.reviewFinalPullRequest)
        #expect(again.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("b")))
        let reopened = try await given.decisions().items.first
        #expect(reopened?.answer == nil)
        #expect(reopened?.visible == true)
        // 自動の直しの回数には数えない
        #expect(FinalChain(jobs: try await given.jobs()).automaticFixes == 0)
    }

    @Test func decisionIsRejectedWhenNotAnswerable() async throws {
        try await given.reviewing()
        // 人が見た後に head が進んだ
        try await given.answer("d1", .ok, head: Fixture.sha("b"))
        // 無いカード・内部の細部のカード
        try await given.answer("d9", .ok)
        try await given.answer("d2", .ok)
        #expect(try await process() == [
            .rejected(kind: "decision", reason: "最終 PR の head が変わった（今は aaaaaaa）。新しい head を見てから送り直す"),
            .rejected(kind: "decision", reason: "判断のカード d9 が無い"),
            .rejected(kind: "decision", reason: "d2 は内部の細部の仮決めで、答えるカードでない")
        ])
        #expect(try await given.decisions().items.allSatisfy { $0.answer == nil })

        // 答え直しは受け付けない（変えたいときは、最終 PR への指示を出す）
        try await given.answer("d1", .ok)
        #expect(try await process() == [.accepted(kind: "decision")])
        try await given.answer("d1", .fix, note: "やっぱり直して")
        #expect(try await process() == [
            .rejected(kind: "decision", reason: "判断のカード d1 にはもう答えている。変えたいときは、最終 PR への指示を出す")
        ])
        #expect(try await given.decisions().items.first?.answer?.choice == .ok)
    }

    @Test func decisionToFixIsRejectedWhileFixing() async throws {
        try await given.finished(decisions: [Fixture.decision("d1"), Fixture.decision("d2")])
        let review = try await given.openedFinalPullRequest(visible: ["d1", "d2"])
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .ready, mergeRisks: []))
        _ = try await given.advance()
        try await given.answer("d1", .alternative, note: "2 行にする案で")
        #expect(try await process() == [.accepted(kind: "decision")])
        // 1 つ目の直しが動いている間は、ほかのカードで直させない（OK は受け付ける）
        try await given.answer("d2", .fix, note: "色を戻して")
        #expect(try await process() == [.rejected(kind: "decision", reason: FinalPullRequestState.busy)])
        try await given.answer("d2", .ok)
        #expect(try await process() == [.accepted(kind: "decision")])
        #expect(try await given.jobs().filter { $0.kind == .fixFinalPullRequest }.count == 1)
    }

    @Test func decisionIsRejectedBeforeFinalPullRequestIsReviewed() async throws {
        try await given.finished(decisions: [Fixture.decision("d1")])
        _ = try await given.advance()
        try await given.answer("d1", .ok)
        #expect(try await process() == [.rejected(kind: "decision", reason: "最終 PR のレビューがまだ無い")])
    }

    // MARK: - マージの承認

    @Test func approveMergeCreatesMergeWithApprovedHead() async throws {
        let review = try await given.reviewing()
        try await given.answer("d1", .ok)
        let intent = try await given.approve()
        #expect(try await process() == [.accepted(kind: "decision"), .accepted(kind: "approveMerge")])
        let merge = try await given.job(CommanderContext.jobID(.mergeFinalPullRequest, origin: intent, seed: ""))
        #expect(merge.kind == .mergeFinalPullRequest)
        #expect(merge.origin == intent)
        #expect(merge.dependsOn == [review.id])
        #expect(merge.assignedMac == Fixture.commander)
        #expect(merge.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("a")))

        // マージした: 片付けを作り、merged にして、人の承認でマージしたことを記録する
        try await given.succeed(merge, outputs: .init(commit: Fixture.sha("e")))
        _ = try await given.next(.cleanUp)
        let merged = try await given.epic()
        #expect(merged.stage == .merged)
        #expect(merged.merge == EpicFile.Merge(commit: Fixture.sha("e"), approval: intent, at: try #require(merged.merge?.at)))
    }

    @Test func approvedMergeIsMarkedMergedInLoopOrder() async throws {
        // 司令塔の 1 周と同じ順（人の意図 → ジョブの見回り → タスクの流れ）で、承認からマージ済みまで進める
        let review = try await given.reviewing()
        try await given.answer("d1", .ok)
        let intent = try await given.approve()
        #expect(try await process() == [.accepted(kind: "decision"), .accepted(kind: "approveMerge")])
        var merge = try await given.job(CommanderContext.jobID(.mergeFinalPullRequest, origin: intent, seed: ""))
        #expect(merge.dependsOn == [review.id])

        // ワーカーがマージのジョブを引き受け、成功を書いた（ジョブの状態は、見回りが試行から決める）
        merge.state = .running
        merge.attempts = 1
        try await given.put(merge, at: StatePath.job(Fixture.repo, epic: Fixture.epicID, job: merge.id))
        let time = Timestamp(Fixture.now)
        let attempt = AttemptFile(
            job: merge.id,
            number: 1,
            mac: Fixture.commander,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            outputs: .init(pullRequest: Fixture.pullRequest, commit: Fixture.sha("e"), branch: "askhub/\(Fixture.epicID)")
        )
        try await given.put(attempt, at: StatePath.attempt(Fixture.repo, epic: Fixture.epicID, job: merge.id, number: 1))
        #expect(try await given.epic().stage == .reviewing)

        let swept = try await JobSweep(context: given.context).sweepAll()
        #expect(swept.changed.map(\.id) == [merge.id])
        #expect(swept.changed.first?.state == .succeeded)
        let advanced = await given.flow.advance(epics: swept.epics, jobs: swept.jobs)
        #expect(advanced.created.map(\.kind) == [.cleanUp])
        let merged = try await given.epic()
        #expect(merged.stage == .merged)
        #expect(merged.merge?.commit == Fixture.sha("e"))
        #expect(merged.merge?.approval == intent)
    }

    @Test func approveMergeIsRejectedUntilEverythingIsSettled() async throws {
        try await given.reviewing()
        // 答えていない見えるカードがある・head が進んだ
        try await given.approve()
        try await given.approve(head: Fixture.sha("b"))
        #expect(try await process() == [
            .rejected(kind: "approveMerge", reason: "答えていない判断のカードがある（d1）。すべてに答えてから承認する"),
            .rejected(kind: "approveMerge", reason: "最終 PR の head が変わった（今は aaaaaaa）。新しい head を見てから送り直す")
        ])

        // 直してほしいと答えた: 直しが動いている（finalizing）間は承認できない
        try await given.answer("d1", .fix, note: "2 行にして")
        try await given.approve()
        #expect(try await process() == [
            .accepted(kind: "decision"),
            .rejected(kind: "approveMerge", reason: "マージを承認できる段階でない（今は finalizing）")
        ])
        #expect(try await !given.jobs().contains { $0.kind == .mergeFinalPullRequest })
    }

    @Test func approveMergeIsRejectedWhileHumanFixWaitsAfterCrash() async throws {
        // 人の直しを作った後、finalizing に戻す前に止まった（reviewing のまま直しがある）
        let review = try await given.reviewing()
        try await given.answer("d1", .ok)
        #expect(try await process() == [.accepted(kind: "decision")])
        let origin = IntentReference(keyId: given.keyID, nonce: .generate(at: Fixture.now))
        let input = FixTaskInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("a"), reason: .human)
        let final = try #require(FinalJobs(context: given.context, epic: try await given.epic()))
        try await given.context.create(try await final.job(.fixFinalPullRequest, input: input, after: review, origin: origin, seed: ""))
        try await given.approve()
        #expect(try await process() == [.rejected(kind: "approveMerge", reason: FinalPullRequestState.busy)])
    }

    // MARK: - 最終 PR への指示

    @Test func instructFinalStartsHumanFix() async throws {
        let review = try await given.reviewing()
        let intent = try await given.instruct("ボタンの文言を「保存」にして")
        #expect(try await process() == [.accepted(kind: "instructFinal")])
        let fix = try await given.job(FinalPullRequestState.humanFixID(intent))
        #expect(fix.origin == intent)
        #expect(fix.dependsOn == [review.id])
        #expect(fix.input(as: FixTaskInput.self) == FixTaskInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("a"), reason: .human))
        #expect(try await given.epic().stage == .finalizing)

        // 直しが動いている間の指示・古い head への指示は断る
        try await given.instruct("もう 1 つ")
        try await given.instruct("古い head", head: Fixture.sha("b"))
        #expect(try await process() == [
            .rejected(kind: "instructFinal", reason: FinalPullRequestState.busy),
            .rejected(kind: "instructFinal", reason: "最終 PR の head が変わった（今は aaaaaaa）。新しい head を見てから送り直す")
        ])
    }

    @Test func instructFinalWaitsForRunningReview() async throws {
        // レビューが動いている間（finalizing）も、見ている head への指示は受け付ける。直しはレビューが終わってから動く
        try await given.finished()
        let review = try await given.openedFinalPullRequest()
        let intent = try await given.instruct("ログを減らして")
        #expect(try await process() == [.accepted(kind: "instructFinal")])
        let fix = try await given.job(FinalPullRequestState.humanFixID(intent))
        #expect(fix.dependsOn == [review.id])
        // レビューが直す判定を出しても、人の直しを先にする（自動の直しは作らない）
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .fixCI, findings: "落ちた"))
        #expect(try await given.advance().created.isEmpty)
    }

    @Test func instructFinalIsRejectedOutsideFinalStages() async throws {
        try await given.finished()
        try await given.instruct("直して")
        #expect(try await process() == [.rejected(kind: "instructFinal", reason: "最終 PR の段階でない（今は running）")])
    }

    // MARK: - やり直し

    @Test func handlersAreIdempotent() async throws {
        let review = try await given.reviewing()
        let context = given.context
        let decision = DecisionIntent(
            target: DecisionTarget(repo: Fixture.repo, epic: Fixture.epicID, decision: "d1", head: Fixture.sha("a")),
            answer: .fix,
            note: "2 行にして",
            intent: IntentReference(keyId: given.keyID, nonce: .generate(at: Fixture.now))
        )
        let envelope = IntentEnvelope(
            kind: DecisionIntent.kind,
            repo: Fixture.repo,
            target: decision.target.target,
            targetVersion: decision.target.targetVersion,
            payload: decision.payload,
            issuedAt: Timestamp(Fixture.now),
            nonce: decision.intent.nonce,
            keyId: decision.intent.keyId
        )
        // 答えを書いた後、直しを作る前に止まった: もう一度処理すると、答えはそのままで直しを作る
        #expect(try await DecisionHandler().handle(envelope, in: context) == .accept)
        var epic = try await given.epic()
        epic.stage = .reviewing
        try await given.put(epic, at: StatePath.epic(Fixture.repo, Fixture.epicID))
        #expect(try await DecisionHandler().handle(envelope, in: context) == .accept)
        #expect(try await given.epic().stage == .finalizing)
        #expect(try await given.jobs().filter { $0.dependsOn.contains(review.id) }.count == 1)
        #expect(try await given.decisions().items.first?.answer?.intent == decision.intent)
    }
}
