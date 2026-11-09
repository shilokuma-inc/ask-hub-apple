import Foundation

/// デモのデータで動く窓口。GitHub には接続しない。
///
/// 人の意図を受けると状態を書き換え（状態リポジトリで、司令塔が受け取る前に送った結果を先に出すのと同じ）、
/// 機械の反応（説明が届く・ロックが外れる・ゴールができる など）を `reactionDelay` 秒の後に起こす。
/// 送った意図は司令塔の受け取り待ちとして記録し、`receiptDelay` 秒の後に受け付ける。テストでは 0 にして、次の取得ですぐ反映させる
final class DemoClientService: ClientService {
    var state: ClientSnapshot
    let scenario: DemoScenario
    let reactionDelay: TimeInterval
    let refreshInterval: Duration
    /// 送るのにかかる時間（送っている間の画面を見るため。既定は待たない）
    let sendDelay: Duration
    /// 司令塔が送った意図を受け取るまでの秒数（受け取り待ちの画面を見るため。既定は機械の反応の半分）
    let receiptDelay: TimeInterval
    /// 司令塔が送った意図を断る（断られたときの画面を見るため）。断る意図は状態に当てない
    let rejectsIntents: Bool
    let now: () -> Date
    private var scheduled: [Reaction] = []
    private var nextPullRequestNumber = 60
    /// 送った意図と時刻
    private var sends: [Send] = []
    /// 受け取りを長く遅らせると決めたとき（司令塔が止まっている場面）の、司令塔の生きている印（起動した時点で古い）。ほかの場面では nil
    private let stoppedCommanderSeenAt: Date?

    /// 送った意図と、司令塔の受け取りを待つ記録の id
    private struct Send {
        var intent: HumanIntent
        var sentAt: Date
        var intentIDs: [String]
    }

    /// 断るときの理由（デモ）
    static let rejectionReason = "デモ: 司令塔が断ったときの画面です"

    private struct Reaction {
        var dueAt: Date
        var apply: (inout ClientSnapshot) -> Void
    }

    init(
        scenario: DemoScenario = .standard,
        reactionDelay: TimeInterval = 4,
        refreshInterval: Duration = .seconds(2),
        sendDelay: Duration = .zero,
        receiptDelay: TimeInterval? = nil,
        rejectsIntents: Bool = false,
        now: @escaping () -> Date = Date.init
    ) {
        self.scenario = scenario
        self.reactionDelay = reactionDelay
        self.refreshInterval = refreshInterval
        self.sendDelay = sendDelay
        self.receiptDelay = receiptDelay ?? reactionDelay / 2
        self.rejectsIntents = rejectsIntents
        self.now = now
        state = scenario.snapshot(now: now())
        let stopped = (receiptDelay ?? 0) >= ReflectionMessage.commanderSilence
        stoppedCommanderSeenAt = stopped ? now().addingTimeInterval(-2 * ReflectionMessage.commanderSilence) : nil
    }

    func fetchSnapshot() async throws -> ClientSnapshot {
        if scenario == .failing {
            throw ClientServiceError(message: "GitHub に接続できませんでした（デモ: 読めないときの画面）")
        }
        applyDueReactions()
        var snapshot = state
        snapshot.fetchedAt = now()
        // 止まっている場面でなければ、司令塔はいま動いていることにする
        snapshot.commanderSeenAt = stoppedCommanderSeenAt ?? now()
        return snapshot
    }

    @discardableResult
    func perform(_ intent: HumanIntent) async throws -> SendReceipt {
        if sendDelay > .zero {
            try await Task.sleep(for: sendDelay)
        }
        let sentAt = now()
        var receipt = rejectsIntents ? SendReceipt() : apply(intent)
        if receipt.sent.isEmpty {
            receipt.sent = recordReceipt(of: intent, requestedEpicID: receipt.requestedEpicID, at: sentAt)
        }
        sends.append(Send(intent: intent, sentAt: sentAt, intentIDs: receipt.intentIDs))
        return receipt
    }

    func lastSend(of intent: HumanIntent) -> SentRecord? {
        sends.last { $0.intent == intent }.map { send in
            let isWaiting = send.intentIDs.contains { id in state.sentIntents.first { $0.id == id }?.state == .waiting }
            return SentRecord(sentAt: send.sentAt, isWaiting: isWaiting)
        }
    }

    /// 送った意図を、司令塔の受け取り待ちとして記録し（対象ごとに 1 つ。状態リポジトリでまとめて OK がカードごとの意図になるのと同じ）、
    /// `receiptDelay` 秒の後に受け付ける（`rejectsIntents` なら断る）。記録した意図を返す
    private func recordReceipt(of intent: HumanIntent, requestedEpicID: Epic.ID?, at date: Date) -> [SendReceipt.Sent] {
        var targets: [IntentTarget?] = intent.targets
        if let requestedEpicID {
            targets = [.request(epicID: requestedEpicID)]
        } else if targets.isEmpty {
            targets = [nil]
        }
        // 状態リポジトリの「送った意図」と同じく、epic の題を添える
        let epicTitle = (requestedEpicID ?? intent.targets.first?.epicID).flatMap { state.epic($0)?.title }
        let title = [intent.label, epicTitle].compactMap(\.self).joined(separator: " · ")
        let sent = targets.map { target in
            let id = "intent-\(UUID().uuidString)"
            state.sentIntents.insert(SentIntentStatus(id: id, title: title, sentAt: date, state: .waiting, target: target), at: 0)
            return SendReceipt.Sent(id: id, target: target)
        }
        let rejects = rejectsIntents
        scheduleReceipt { [now] snapshot in
            for item in sent {
                guard let index = snapshot.sentIntents.firstIndex(where: { $0.id == item.id }) else {
                    continue
                }
                snapshot.sentIntents[index].state = rejects ? .rejected(at: now(), reason: Self.rejectionReason) : .accepted(at: now())
            }
        }
        return sent
    }

    /// 司令塔が送った意図を受け取ったときの書き換えを、`receiptDelay` 秒の後に起こす（一時停止していても受け取る）
    func scheduleReceipt(_ apply: @escaping (inout ClientSnapshot) -> Void) {
        scheduled.append(Reaction(dueAt: now().addingTimeInterval(receiptDelay), apply: apply))
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

    /// epic を進める反応。一時停止している間は当てずに、再開するまで先送りする
    func scheduleProgress(of epicID: Epic.ID, after factor: Double = 1, _ apply: @escaping (inout ClientSnapshot) -> Void) {
        schedule(after: factor) { [weak self] snapshot in
            guard snapshot.epic(epicID)?.isPaused != true else {
                self?.scheduleProgress(of: epicID, after: 1, apply)
                return
            }
            apply(&snapshot)
        }
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

    /// タスクの実装を、epic を回す Mac で始める
    mutating func startTask(at index: Int, attempt: Int, date: Date) {
        tasks[index].state = .inProgress(.implementing)
        let worker = macID.map { EpicActivity.Worker(macID: $0, heartbeatAt: date) }
        let step = WorkStep.task(tasks[index].id, .implementing)
        activities = [EpicActivity(kind: .step(step, .running(attempt: attempt)), since: date, worker: worker)]
    }

    mutating func log(_ text: String, at date: Date, isFailure: Bool = false) {
        history.append(HistoryEntry(date: date, text: text, isFailure: isFailure))
        updatedAt = date
    }
}
