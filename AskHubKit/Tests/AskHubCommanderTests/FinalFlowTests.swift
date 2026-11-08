@testable import AskHubCommander
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// すべてのタスクが済んだ後の最終 PR の段取り（検証 → 仕分け → 最終 PR → レビュー →（直し → レビュー）→ マージ → 片付け）
struct FinalFlowTests {
    typealias Fixture = FinalFlowFixture
    let given = Fixture()

    // MARK: - 自動でマージする

    @Test func runsFinalStepsUntilAutomaticMerge() async throws {
        try await given.finished(decisions: [Fixture.decision("d1"), Fixture.decision("d2")])
        // タスクがすべて済んだ: finalizing にして、epic の Mac に検証（全部のテスト）を作る
        var step = try await given.advance()
        let verify = try #require(step.created.first)
        #expect(step.created.map(\.kind) == [.verifyBeforeFinal])
        #expect(step.notes.first?.contains("すべて済んだ") == true)
        #expect(verify.assignedMac == Fixture.laptop)
        #expect(verify.needs == .init(claude: false, build: true))
        #expect(verify.dependsOn.isEmpty)
        #expect(verify.input?.isEmpty == true)
        #expect(verify.origin == Fixture.origin)
        #expect(verify.task == nil)
        #expect(try await given.epic().stage == .finalizing)
        // 検証が動いている間は待つ
        #expect(try await given.advance() == TaskFlow.Advanced())

        // 検証が通った: 仕分けていない仮決めがあるので、常時オンの Mac に判断の仕分けを作る
        try await given.succeed(verify)
        let classify = try await given.next(.classifyDecisions)
        #expect(classify.assignedMac == Fixture.commander)
        #expect(classify.needs == .init(claude: true, build: false))
        #expect(classify.dependsOn == [verify.id])

        // 仕分けた: 見える仮決めは無い（どれも内部の細部）。最終 PR を出す
        try await given.succeed(classify, outputs: .init(visibleDecisions: []))
        let open = try await given.next(.openFinalPullRequest)
        #expect(try await given.decisions().items.map(\.visible) == [false, false])
        #expect(open.assignedMac == Fixture.commander)
        #expect(open.dependsOn == [classify.id])

        // 最終 PR を出した: epic に書き、出した head でレビューを作る
        try await given.succeed(open, outputs: .init(pullRequest: Fixture.pullRequest, commit: Fixture.sha("a")))
        let review = try await given.next(.reviewFinalPullRequest)
        #expect(try await given.epic().finalPullRequest == Fixture.pullRequest)
        #expect(review.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("a")))
        #expect(review.assignedMac == Fixture.commander)
        #expect(review.needs == .init(claude: true, build: false))
        #expect(review.dependsOn == [open.id])

        // 通った・手動の条件が無い: 見た head を固定してマージを作る（人を待たない）
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .ready, mergeRisks: []))
        let merge = try await given.next(.mergeFinalPullRequest)
        #expect(merge.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("a")))
        #expect(merge.assignedMac == Fixture.commander)
        #expect(merge.origin == Fixture.origin)
        #expect(merge.dependsOn == [review.id])
        #expect(try await given.epic().stage == .finalizing)

        // マージした: epic の Mac に片付けを作り、epic を merged にする
        try await given.succeed(merge, outputs: .init(commit: Fixture.sha("e")))
        step = try await given.advance()
        let cleanUp = try #require(step.created.first)
        #expect(step.created.map(\.kind) == [.cleanUp])
        #expect(cleanUp.assignedMac == Fixture.laptop)
        #expect(cleanUp.dependsOn == [merge.id])
        #expect(step.notes.contains { $0.contains("マージした") })
        #expect(try await given.epic().stage == .merged)
        #expect(try await given.advance() == TaskFlow.Advanced())
    }

    @Test func opensWithoutClassifyingWhenThereAreNoDecisions() async throws {
        try await given.finished()
        let verify = try await given.next(.verifyBeforeFinal)
        try await given.succeed(verify)
        let open = try await given.next(.openFinalPullRequest)
        #expect(open.dependsOn == [verify.id])
    }

    // MARK: - 人の確認を待つ

    @Test func waitsForHumanWhenVisibleDecisionsRemain() async throws {
        try await given.finished(decisions: [Fixture.decision("d1"), Fixture.decision("d2")])
        let review = try await given.openedFinalPullRequest(visible: ["d1"])
        #expect(try await given.decisions().items.map(\.visible) == [true, false])
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .ready, mergeRisks: []))
        let step = try await given.advance()
        #expect(step.created.isEmpty)
        #expect(step.notes.first?.contains("人の確認を待つ（見える仮決め 1 件）") == true)
        #expect(try await given.epic().stage == .reviewing)
        // 人の承認があるまで、マージを作らない
        #expect(try await given.advance().created.isEmpty)
    }

    @Test(arguments: [
        [MergeRisk(kind: .security, reason: "トークンをログに出す")],
        nil
    ])
    func waitsForHumanWhenReviewFoundRisksOrLacksThem(_ risks: [MergeRisk]?) async throws {
        try await given.finished()
        let review = try await given.openedFinalPullRequest()
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .ready, mergeRisks: risks))
        let step = try await given.advance()
        #expect(step.created.isEmpty)
        #expect(try await given.epic().stage == .reviewing)
        let why = risks == nil ? "mergeRisks" : "security: トークンをログに出す"
        #expect(step.notes.first?.contains(why) == true)
    }

    // MARK: - 直し

    @Test func fixesUpToLimitThenHandsOverToHuman() async throws {
        try await given.finished()
        var review = try await given.openedFinalPullRequest()
        for round in 1...3 {
            let verdict: ReviewVerdict = round == 2 ? .fixReview : .fixCI
            let seen = try #require(review.input(as: PullRequestInput.self))
            try await given.succeed(review, outputs: .init(commit: seen.head, verdict: verdict, findings: "build / build が落ちた"))
            let fix = try await given.next(.fixFinalPullRequest)
            // epic の Mac がオンラインなので、作業場所が温まっている epic の Mac で直す
            #expect(fix.assignedMac == Fixture.laptop)
            #expect(fix.needs == .init(claude: true, build: true))
            #expect(fix.state == .assigned)
            #expect(fix.dependsOn == [review.id])
            let reason: FixTaskInput.Reason = verdict == .fixCI ? .ci : .review
            #expect(fix.input(as: FixTaskInput.self) == FixTaskInput(pullRequest: Fixture.pullRequest, head: seen.head, reason: reason))
            // 直した head で、レビューを作り直す
            let head = Fixture.sha(Character(String(round)))
            let report = TaskOutputReport(summary: "直した")
            try await given.succeed(fix, outputs: .init(pullRequest: Fixture.pullRequest, commit: head, report: report))
            review = try await given.next(.reviewFinalPullRequest)
            #expect(review.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: Fixture.pullRequest, head: head))
            #expect(review.dependsOn == [fix.id])
        }
        // 4 回目の直しは、作るが動かさずに人に渡す（人が「やり直す」を送れば動く）
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("3"), verdict: .fixCI, findings: "まだ落ちる"))
        let step = try await given.advance()
        let handedOver = try #require(step.created.first)
        #expect(handedOver.kind == .fixFinalPullRequest)
        #expect(handedOver.state == .waitingHuman)
        #expect(step.notes.first?.contains("人に渡した") == true)
        #expect(try await given.advance() == TaskFlow.Advanced())
        #expect(try await given.epic().stage == .finalizing)
    }

    @Test func fixRunsOnAlwaysOnMacWhileEpicMacIsOffline() async throws {
        // epic の Mac の生きている印が 31 分前（オフライン）
        try await given.finished(macSeen: 31 * 60)
        let review = try await given.openedFinalPullRequest()
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .fixCI, findings: "落ちた"))
        #expect(try await given.next(.fixFinalPullRequest).assignedMac == Fixture.commander)
    }

    @Test func classifiesDecisionsAddedByFixBeforeReviewing() async throws {
        try await given.finished(decisions: [Fixture.decision("d1")])
        let review = try await given.openedFinalPullRequest(visible: ["d1"])
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .fixReview, findings: "見出しが長い"))
        let fix = try await given.next(.fixFinalPullRequest)
        let report = TaskOutputReport(summary: "直した", decisions: [.init(what: "見出しを 1 行にした", why: "指摘に合わせる")])
        try await given.succeed(fix, outputs: .init(pullRequest: Fixture.pullRequest, commit: Fixture.sha("b"), report: report))
        // 直しの仮決めは、ゴールの最後のタスクと最終 PR のものとして足し、レビューの前に仕分ける
        let classify = try await given.next(.classifyDecisions)
        #expect(classify.dependsOn == [fix.id])
        let added = try #require(try await given.decisions().items.last)
        #expect(added.id == "d2")
        #expect(added.task == "t2")
        #expect(added.pullRequest == Fixture.pullRequest)
        #expect(added.visible == nil)
        // 仕分けた: 仕分け済みの d1 は変えず、d2 だけを写して、直した head でレビューする
        try await given.succeed(classify, outputs: .init(visibleDecisions: ["d2"]))
        let again = try await given.next(.reviewFinalPullRequest)
        #expect(try await given.decisions().items.map(\.visible) == [true, true])
        #expect(again.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("b")))
        #expect(again.dependsOn == [classify.id])
    }

    @Test func reviewsAgainWhenHeadMovedDuringReview() async throws {
        try await given.finished()
        let review = try await given.openedFinalPullRequest()
        // 見ている間に head が進んだ: ワーカーは判定を書かずに今の head を返す。その head でレビューし直す
        try await given.succeed(review, outputs: .init(pullRequest: Fixture.pullRequest, commit: Fixture.sha("b")))
        let again = try await given.next(.reviewFinalPullRequest)
        #expect(again.input(as: PullRequestInput.self) == PullRequestInput(pullRequest: Fixture.pullRequest, head: Fixture.sha("b")))
        #expect(again.dependsOn == [review.id])
        // 判定も新しい head も無ければ、進めずに知らせる
        try await given.succeed(again, outputs: .init(pullRequest: Fixture.pullRequest, commit: Fixture.sha("b")))
        let step = try await given.advance()
        #expect(step.created.isEmpty)
        #expect(step.notes.first?.contains("判定が無い") == true)
    }

    // MARK: - 結果が欠けている

    @Test func waitsWithNoteWhenOutputsAreMissing() async throws {
        try await given.finished(decisions: [Fixture.decision("d1")])
        try await given.succeed(try await given.next(.verifyBeforeFinal))
        try await given.succeed(try await given.next(.classifyDecisions))
        var step = try await given.advance()
        #expect(step.created.isEmpty)
        #expect(step.notes.first?.contains("visibleDecisions") == true)

        let other = Fixture()
        try await other.finished()
        try await other.succeed(try await other.next(.verifyBeforeFinal))
        try await other.succeed(try await other.next(.openFinalPullRequest), outputs: .init(pullRequest: Fixture.pullRequest))
        step = try await other.advance()
        #expect(step.created.isEmpty)
        #expect(step.notes.first?.contains("最終 PR か head のコミットが無い") == true)
    }

    // MARK: - やり直し

    @Test func redoingCreatesNoDuplicateJobs() async throws {
        // finalizing にした後、検証を作る前に止まった: 次の周で検証を作る
        try await given.finished()
        var epic = try await given.epic()
        epic.stage = .finalizing
        try await given.put(epic, at: StatePath.epic(Fixture.repo, Fixture.epicID))
        let verify = try await given.next(.verifyBeforeFinal)
        #expect(try await given.advance() == TaskFlow.Advanced())

        // 同じ見直しの結果で 2 回進めても、ジョブは 1 つ
        try await given.succeed(verify)
        let before = try await given.jobs()
        let first = await given.flow.advance(epics: [try await given.epic()], jobs: before)
        let second = await given.flow.advance(epics: [try await given.epic()], jobs: before)
        #expect(first.created.map(\.id) == second.created.map(\.id))
        #expect(try await given.jobs().filter { $0.kind == .openFinalPullRequest }.count == 1)
    }

    @Test func marksMergedWhenStoppedAfterCreatingCleanUp() async throws {
        try await given.finished()
        let review = try await given.openedFinalPullRequest()
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .ready, mergeRisks: []))
        let merge = try await given.next(.mergeFinalPullRequest)
        try await given.succeed(merge, outputs: .init(commit: Fixture.sha("e")))
        // 片付けを作った後、epic を merged にする前に止まった
        let final = try #require(FinalJobs(context: given.context, epic: try await given.epic()))
        let cleanUp = try await final.job(.cleanUp, input: nil, after: merge, origin: Fixture.origin, seed: "")
        try await given.context.create(cleanUp)
        #expect(try await given.advance().created.isEmpty)
        #expect(try await given.epic().stage == .merged)
    }

    // MARK: - マージの後の片付け

    @Test func keepsWatchingCleanUpForAWhileAfterMerge() async throws {
        try await given.finished()
        let review = try await given.openedFinalPullRequest()
        try await given.succeed(review, outputs: .init(commit: Fixture.sha("a"), verdict: .ready, mergeRisks: []))
        try await given.succeed(try await given.next(.mergeFinalPullRequest), outputs: .init(commit: Fixture.sha("e")))
        let cleanUp = try await given.next(.cleanUp)
        #expect(try await given.epic().stage == .merged)
        // マージした epic でも、片付けのジョブを見張り、epic の Mac のワーカーが引き受けられる
        let swept = try await JobSweep(context: given.context).sweepAll()
        #expect(swept.jobs.contains { $0.id == cleanUp.id })
        #expect(try await given.context.jobsOfEpics(on: Fixture.laptop).contains { $0.id == cleanUp.id })
        // 決めた長さを過ぎたら、見張るのをやめる
        let expired = Fixture.now.addingTimeInterval(EpicFile.cleanUpWindow + 1)
        let later = CommanderContext(store: given.store, mac: Fixture.commander) { expired }
        #expect(try await JobSweep(context: later).sweepAll().jobs.isEmpty)
        #expect(try await later.jobsOfEpics(on: Fixture.laptop).isEmpty)
    }
}
