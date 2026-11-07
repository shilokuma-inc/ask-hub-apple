import Foundation

/// デモのデータで動く窓口。GitHub には接続しない。
///
/// 人の意図を受けると状態を書き換え、機械の反応（説明が届く・ロックが外れる・ゴールができる など）を
/// `reactionDelay` 秒の後に起こす。テストでは 0 にして、次の取得ですぐ反映させる
final class DemoClientService: ClientService {
    var state: ClientSnapshot
    let scenario: DemoScenario
    let reactionDelay: TimeInterval
    let refreshInterval: Duration
    let now: () -> Date
    private var scheduled: [Reaction] = []
    private var nextPullRequestNumber = 60
    /// 送った意図と時刻（デモはすぐ当てるので、司令塔の受け取りを待つものは無い）
    private var sends: [(intent: HumanIntent, sentAt: Date)] = []

    private struct Reaction {
        var dueAt: Date
        var apply: (inout ClientSnapshot) -> Void
    }

    init(
        scenario: DemoScenario = .standard,
        reactionDelay: TimeInterval = 4,
        refreshInterval: Duration = .seconds(2),
        now: @escaping () -> Date = Date.init
    ) {
        self.scenario = scenario
        self.reactionDelay = reactionDelay
        self.refreshInterval = refreshInterval
        self.now = now
        state = scenario.snapshot(now: now())
    }

    func fetchSnapshot() async throws -> ClientSnapshot {
        if scenario == .failing {
            throw ClientServiceError(message: "GitHub に接続できませんでした（デモ: 読めないときの画面）")
        }
        applyDueReactions()
        var snapshot = state
        snapshot.fetchedAt = now()
        return snapshot
    }

    @discardableResult
    func perform(_ intent: HumanIntent) async throws -> SendReceipt {
        sends.append((intent, now()))
        return apply(intent)
    }

    func lastSend(of intent: HumanIntent) -> SentRecord? {
        sends.last { $0.intent == intent }.map { SentRecord(sentAt: $0.sentAt, isWaiting: false) }
    }

    /// 期限の来た機械の反応を当てる
    func applyDueReactions() {
        let date = now()
        let due = scheduled.filter { $0.dueAt <= date }
        scheduled.removeAll { $0.dueAt <= date }
        for reaction in due {
            reaction.apply(&state)
        }
    }

    func schedule(after factor: Double = 1, _ apply: @escaping (inout ClientSnapshot) -> Void) {
        scheduled.append(Reaction(dueAt: now().addingTimeInterval(reactionDelay * factor), apply: apply))
    }

    func nextPullRequest() -> Int {
        nextPullRequestNumber += 1
        return nextPullRequestNumber
    }
}

// MARK: - 状態の書き換えの道具

extension ClientSnapshot {
    mutating func updateEpic(_ id: Epic.ID, _ change: (inout Epic) -> Void) {
        guard let index = epics.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&epics[index])
    }

    mutating func updateMac(_ id: Mac.ID, _ change: (inout Mac) -> Void) {
        guard let index = macs.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&macs[index])
    }

    /// その epic のリポジトリを前回回した Mac を覚える（次に開始するときの既定）
    mutating func recordLastMac(_ macID: Mac.ID, forEpic epicID: Epic.ID) {
        guard let repositoryID = epic(epicID)?.repositoryID, let index = repositories.firstIndex(where: { $0.id == repositoryID }) else {
            return
        }
        repositories[index].lastMacID = macID
    }
}

extension Epic {
    mutating func updateQuestion(_ id: Question.ID, _ change: (inout Question) -> Void) {
        guard let index = questions.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&questions[index])
    }

    mutating func updateDecision(_ id: DecisionCard.ID, _ change: (inout DecisionCard) -> Void) {
        guard var review = finalReview, let index = review.decisions.firstIndex(where: { $0.id == id }) else {
            return
        }
        change(&review.decisions[index])
        finalReview = review
    }

    mutating func removeActivities(where predicate: (EpicActivity.Kind) -> Bool) {
        activities.removeAll { predicate($0.kind) }
    }

    mutating func log(_ text: String, at date: Date, isFailure: Bool = false) {
        history.append(HistoryEntry(date: date, text: text, isFailure: isFailure))
        updatedAt = date
    }
}
