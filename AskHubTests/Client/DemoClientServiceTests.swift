@testable import AskHub
import Foundation
import Testing

/// デモの窓口が、人の意図を受けて状態を変え、機械の反応を起こすこと
@MainActor
struct DemoClientServiceTests {
    /// テストで進める時計
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let clock = Clock()

    private func makeService(_ scenario: DemoScenario = .standard) -> DemoClientService {
        DemoClientService(scenario: scenario, reactionDelay: 10, refreshInterval: .seconds(1)) { [clock] in clock.now }
    }

    private func question(_ service: DemoClientService, _ epicID: Epic.ID, _ id: Question.ID) -> Question? {
        service.state.epic(epicID)?.question(id)
    }

    /// 依存先が決まると見直してからロックが外れる
    @Test
    func unlocksDependentAfterReview() async throws {
        let service = makeService()
        try await service.perform(.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "b", note: ""))
        #expect(question(service, "recipe-weekly", "Q5")?.state == .reviewing)
        // Q6 は Q4（説明待ち）にも依存するので、まだロックのまま
        #expect(question(service, "recipe-weekly", "Q6")?.state == .locked)

        clock.now.addTimeInterval(11)
        _ = try await service.fetchSnapshot()
        let q5 = try #require(question(service, "recipe-weekly", "Q5"))
        #expect(q5.state == .open)
        #expect(q5.revisionNote != nil)
    }

    /// 回答を直すと依存する質問はロックに戻る
    @Test
    func changingAnswerRelocksDependents() async throws {
        let service = makeService()
        try await service.perform(.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "b", note: ""))
        clock.now.addTimeInterval(11)
        _ = try await service.fetchSnapshot()
        try await service.perform(.answer(epicID: "recipe-weekly", questionID: "Q5", optionID: "a", note: ""))

        // Q3 を直すと、Q5 の回答を取り消して見直しからやり直す
        try await service.perform(.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: ""))
        #expect(question(service, "recipe-weekly", "Q5")?.state == .reviewing)
    }

    /// 説明を求めると説明待ちになりしばらくして届く
    @Test
    func explanationArrivesLater() async throws {
        let service = makeService()
        try await service.perform(.requestExplanation(epicID: "habit-export", questionID: "Q2", request: "違いが分からない"))
        #expect(question(service, "habit-export", "Q2")?.isAwaitingExplanation == true)

        clock.now.addTimeInterval(20)
        _ = try await service.fetchSnapshot()
        let q2 = try #require(question(service, "habit-export", "Q2"))
        #expect(q2.state == .open)
        #expect(q2.latestExplanation?.body != nil)
    }

    /// 全部決まると着手前の確認を経てゴールができる
    @Test
    func preflightProducesGoal() async throws {
        let service = makeService()
        try await service.perform(.answer(epicID: "habit-export", questionID: "Q2", optionID: "b", note: ""))
        try await service.perform(.answer(epicID: "habit-export", questionID: "Q3", optionID: nil, note: "習慣ログ_年-月.csv"))
        try await service.perform(.answer(epicID: "habit-export", questionID: "Q4", optionID: "c", note: ""))
        #expect(service.state.epic("habit-export")?.stage == .preflight)

        clock.now.addTimeInterval(20)
        _ = try await service.fetchSnapshot()
        let epic = try #require(service.state.epic("habit-export"))
        #expect(epic.stage == .goal)
        #expect(epic.goal?.decided.contains { $0.questionID == "Q4" } == true)
    }

    /// 開始すると、司令塔が受け取るのを待ち、受け取ったらその Mac で作業場所を用意し、作業ブランチができたらタスク 1 の実装を始める
    @Test
    func startBeginsImplementationOnMac() async throws {
        let service = makeService()
        let intent = HumanIntent.start(epicID: "budget-limit", macID: DemoData.macBookProID)
        let receipt = try await service.perform(intent)
        // 受け取られるまでは、同じ開始を送り直さない
        #expect(service.lastSend(of: intent)?.isWaiting == true)
        let sent = try #require(try await service.fetchSnapshot().sentIntents.first { $0.id == receipt.intentID })
        #expect(sent.state == .waiting)
        let waiting = try #require(service.state.epic("budget-limit"))
        #expect(waiting.stage == .implementing)
        #expect(waiting.macID == DemoData.macBookProID)
        #expect(waiting.workspace == .pending)
        #expect(waiting.activities.map(\.kind) == [.startRequested(macID: DemoData.macBookProID)])

        clock.now += 10
        let accepted = try await service.fetchSnapshot()
        #expect(accepted.sentIntents.first { $0.id == receipt.intentID }?.state == .accepted(at: clock.now))
        let preparing = try #require(accepted.epic("budget-limit"))
        #expect(preparing.workspace == .preparing)
        #expect(preparing.activities.map(\.kind) == [.step(.prepareWorkspace, .running(attempt: 1))])
        #expect(preparing.history.last?.text == "MacBook Pro 14 で開始しました")
        #expect(service.lastSend(of: intent)?.isWaiting == false)
        #expect(accepted.mac(DemoData.macBookProID)?.jobs.map(\.title) == ["月の上限の通知: 作業場所の用意"])

        clock.now += 10
        let implementing = try #require(try await service.fetchSnapshot().epic("budget-limit"))
        #expect(implementing.workspace == .ready(branch: "askhub/budget-limit"))
        #expect(implementing.tasks.first?.state == .inProgress(.implementing))
        #expect(implementing.activities.first?.worker?.macID == DemoData.macBookProID)
        #expect(service.state.mac(DemoData.macBookProID)?.jobs.map(\.title) == ["月の上限の通知: タスク 1 の実装"])
    }

    /// 開始した後に一時停止すると、再開するまで段取りを進めない
    @Test
    func pausedStartWaitsUntilResumed() async throws {
        let service = makeService()
        try await service.perform(.start(epicID: "budget-limit", macID: DemoData.macBookProID))
        try await service.perform(.pause(epicID: "budget-limit"))
        clock.now += 30
        let paused = try #require(try await service.fetchSnapshot().epic("budget-limit"))
        #expect(paused.isPaused)
        #expect(paused.workspace == .pending)

        try await service.perform(.resume(epicID: "budget-limit"))
        clock.now += 10
        #expect(try await service.fetchSnapshot().epic("budget-limit")?.workspace == .preparing)
        clock.now += 10
        #expect(try await service.fetchSnapshot().epic("budget-limit")?.workspace == .ready(branch: "askhub/budget-limit"))
    }

    /// 開始のときは、前回そのリポジトリを回した Mac を既定で選ぶ。前回の Mac がオフラインなら選ばない
    @Test
    func defaultStartMacIsLastOnlineMac() {
        let snapshot = makeService().state
        #expect(snapshot.defaultStartMacID(for: DemoData.repositoryID("pocket-budget-ios")) == DemoData.macBookProID)
        // 家事シェアを前回回した MacBook Air はオフライン
        #expect(snapshot.defaultStartMacID(for: DemoData.repositoryID("kaji-share-ios")) == nil)
        #expect(snapshot.startableMacs.map(\.id) == [DemoData.macMiniID, DemoData.macBookProID])
    }

    /// 開始した Mac が、そのリポジトリの次の開始の既定になる
    @Test
    func startRemembersMacForRepository() async throws {
        let service = makeService()
        try await service.perform(.start(epicID: "budget-limit", macID: DemoData.macMiniID))
        #expect(service.state.defaultStartMacID(for: DemoData.repositoryID("pocket-budget-ios")) == DemoData.macMiniID)
    }

    /// 対象に加えると候補から外れ、対象のリポジトリに入る（回してよい Mac は選ばない）
    @Test
    func addRepositoryMovesCandidate() async throws {
        let service = makeService()
        let id = DemoData.repositoryID("sleep-log-apple")
        try await service.perform(.addRepository(repositoryID: id))
        #expect(service.state.repository(id) != nil)
        #expect(!service.state.candidateRepositories.contains { $0.id == id })
    }

    /// 判断を全部 OK にすると確かめた head が記録されマージできる
    @Test
    func acceptAllRecordsHeadAndMerges() async throws {
        let service = makeService()
        try await service.perform(.acceptAllDecisions(epicID: "tsundoku-search"))
        let review = try #require(service.state.epic("tsundoku-search")?.finalReview)
        let allConfirmed = review.decisions.allSatisfy(\.isConfirmed)
        #expect(allConfirmed)
        #expect(review.reviewedHeadCommit == review.headCommit)

        try await service.perform(.merge(epicID: "tsundoku-search", headCommit: try #require(review.headCommit)))
        clock.now.addTimeInterval(20)
        _ = try await service.fetchSnapshot()
        #expect(service.state.epic("tsundoku-search")?.stage == .done)
    }

    /// 違う head ではマージしない
    @Test
    func refusesMergeForDifferentHead() async throws {
        let service = makeService()
        try await service.perform(.merge(epicID: "tsundoku-search", headCommit: "0000000"))
        #expect(service.state.epic("tsundoku-search")?.finalReview?.state == .reviewable)
    }

    /// 最終 PR に指示すると、直している間は確かめられず、直したら head が替わって確かめられる
    @Test
    func finalInstructionFixesAndChangesHead() async throws {
        let service = makeService()
        let head = try #require(service.state.epic("tsundoku-search")?.finalReview?.headCommit)
        try await service.perform(.instructFinal(epicID: "tsundoku-search", headCommit: head, instruction: "検索欄を下に"))
        let fixing = try #require(service.state.epic("tsundoku-search")?.finalReview)
        #expect(fixing.state == .checking)
        #expect(fixing.checks.ci == .fixingByRequest)

        clock.now.addTimeInterval(30)
        _ = try await service.fetchSnapshot()
        let fixed = try #require(service.state.epic("tsundoku-search")?.finalReview)
        #expect(fixed.state == .reviewable)
        #expect(fixed.headCommit != head)
    }

    /// 直してほしいと頼むと直してからもう一度出す
    @Test
    func fixRequestComesBackForReview() async throws {
        let service = makeService()
        try await service.perform(.respondToDecision(epicID: "tsundoku-search", decisionID: "d4", reply: .fix("左に置いて")))
        let fixing = service.state.epic("tsundoku-search")?.finalReview?.decisions.first { $0.id == "d4" }
        #expect(fixing?.response == .fixing(request: "左に置いて"))

        clock.now.addTimeInterval(30)
        _ = try await service.fetchSnapshot()
        let decision = try #require(service.state.epic("tsundoku-search")?.finalReview?.decisions.first { $0.id == "d4" })
        #expect(decision.needsReview)
    }

    /// 人がする作業を終えると前提のタスクのロックが外れる
    @Test
    func completingHumanTaskUnlocksTask() async throws {
        let service = makeService()
        try await service.perform(.completeHumanTask(epicID: "rain-draft", taskID: "ht-app-group"))
        clock.now.addTimeInterval(11)
        _ = try await service.fetchSnapshot()
        let epic = try #require(service.state.epic("rain-draft"))
        #expect(epic.humanTask("ht-app-group")?.state == .done)
        #expect(epic.tasks.first { $0.id == "rain-t4" }?.state == .pending)
    }

    /// 依頼の控えは作った epic の id を持つ。送った意図はすぐ当てるので、受け取り待ちにはならない
    @Test
    func requestReceiptPointsToCreatedEpic() async throws {
        let service = makeService()
        let request = HumanIntent.request(repositoryID: DemoData.repositoryID("recipe-apple"), summary: "メモ並べ替え", body: "")
        let receipt = try await service.perform(request)
        let epicID = try #require(receipt.requestedEpicID)
        #expect(service.state.epic(epicID)?.title == "メモ並べ替え")
        #expect(service.lastSend(of: request) == SentRecord(sentAt: clock.now, isWaiting: false))
        #expect(service.lastSend(of: .addRepository(repositoryID: "example/other")) == nil)
    }

    /// 読めない場面では取得が失敗する
    @Test
    func failingScenarioThrows() async {
        let service = makeService(.failing)
        await #expect(throws: ClientServiceError.self) {
            _ = try await service.fetchSnapshot()
        }
    }
}
