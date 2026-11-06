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

    /// 開始するとその Mac で実装が始まる
    @Test
    func startBeginsImplementationOnMac() async throws {
        let service = makeService()
        try await service.perform(.start(epicID: "budget-limit", macID: DemoData.macBookProID))
        let epic = try #require(service.state.epic("budget-limit"))
        #expect(epic.stage == .implementing)
        #expect(epic.macID == DemoData.macBookProID)
        #expect(epic.tasks.first?.state == .inProgress)
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

        try await service.perform(.merge(epicID: "tsundoku-search", headCommit: review.headCommit))
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

    /// 読めない場面では取得が失敗する
    @Test
    func failingScenarioThrows() async {
        let service = makeService(.failing)
        await #expect(throws: ClientServiceError.self) {
            _ = try await service.fetchSnapshot()
        }
    }
}
