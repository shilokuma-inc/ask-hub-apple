@testable import AskHub
import Foundation
import Testing

/// 押した時点で済んだ形にすること: 送り終える前から送った結果を当てる、送れなかった・取り消した・断られたら元に戻す、
/// 押した順に送る、司令塔の受け取りを待つ間だけ受け付けの記録を軽く確かめる
@MainActor
struct OptimisticSendTests {
    /// 状態リポジトリと同じく、書いて司令塔の受け取りを待つ意図と、送り終えていない意図を、送った結果として当てる窓口（回答だけを当てる）
    private final class OverlayService: ClientService {
        var refreshInterval: Duration = .seconds(60)
        var receiptCheckInterval: Duration? = .milliseconds(5)
        /// 司令塔の側の状態
        var remote: ClientSnapshot
        var performed: [HumanIntent] = []
        var performError: ClientServiceError?
        /// true の間は、`finishSending()` を呼ぶまで送り終わらない
        var holdsSending = false
        /// 受け付けの記録を確かめた意図の id（確かめた順）
        var receiptChecks: [String] = []
        var receiptError: ClientServiceError?
        var fetchCount = 0
        private var written: [(intent: HumanIntent, id: String)] = []
        private var sendingWaiters: [CheckedContinuation<Void, Never>] = []
        private var nextID = 0
        let now: Date

        init(now: Date) {
            self.now = now
            remote = DemoScenario.standard.snapshot(now: now)
        }

        func fetchSnapshot() async throws -> ClientSnapshot {
            fetchCount += 1
            return presented([])
        }

        func perform(_ intent: HumanIntent) async throws -> SendReceipt {
            performed.append(intent)
            if holdsSending {
                await withCheckedContinuation { sendingWaiters.append($0) }
            }
            if let performError {
                throw performError
            }
            nextID += 1
            let id = "n\(nextID)"
            let target = intent.targets.first
            remote.sentIntents.insert(SentIntentStatus(id: id, title: intent.label, sentAt: now, state: .waiting, target: target), at: 0)
            written.append((intent, id))
            return SendReceipt(sent: [SendReceipt.Sent(id: id, target: target)])
        }

        func lastSend(of intent: HumanIntent) -> SentRecord? {
            nil
        }

        func snapshot(overlaying intents: [HumanIntent]) -> ClientSnapshot? {
            fetchCount == 0 ? nil : presented(intents)
        }

        func hasReceipt(for intentID: String) async throws -> Bool {
            receiptChecks.append(intentID)
            if let receiptError {
                throw receiptError
            }
            return remote.sentIntents.first { $0.id == intentID }?.state != .waiting
        }

        func finishSending() {
            sendingWaiters.forEach { $0.resume() }
            sendingWaiters = []
        }

        /// 司令塔が受け取り待ちの意図をすべて処理した（受け付けたものは状態に当てる）
        func consumeWaiting(as state: SentIntentStatus.State) {
            if case .accepted = state {
                for item in written where remote.sentIntents.first(where: { $0.id == item.id })?.state == .waiting {
                    Self.apply(item.intent, to: &remote)
                }
            }
            for index in remote.sentIntents.indices where remote.sentIntents[index].state == .waiting {
                remote.sentIntents[index].state = state
            }
        }

        private func presented(_ intents: [HumanIntent]) -> ClientSnapshot {
            var snapshot = remote
            let waiting = written.filter { item in remote.sentIntents.first { $0.id == item.id }?.state == .waiting }
            for intent in waiting.map(\.intent) + intents {
                Self.apply(intent, to: &snapshot)
            }
            return snapshot
        }

        private static func apply(_ intent: HumanIntent, to snapshot: inout ClientSnapshot) {
            guard case let .answer(epicID, questionID, optionID, note) = intent else {
                return
            }
            let response = Question.Response(optionID: optionID, note: note, answeredAt: .now)
            snapshot.updateEpic(epicID) { epic in
                epic.updateQuestion(questionID) { $0.state = .answered(response) }
            }
        }
    }

    /// テストで進める時計
    private final class Clock {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let answer = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: "")
    private let target = IntentTarget.question(epicID: "recipe-weekly", questionID: "Q3")

    private func makeStore(clock: Clock? = nil) async -> (OverlayService, ClientStore) {
        let service = OverlayService(now: start)
        let clock = clock ?? Clock(start)
        let store = ClientStore(service: service, undoDelay: .seconds(60), now: { clock.now })
        await store.refresh()
        return (service, store)
    }

    private func isAnswered(_ store: ClientStore) -> Bool {
        if case .answered? = store.epic("recipe-weekly")?.question("Q3")?.state {
            return true
        }
        return false
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: 済んだ形にする

    /// 押した直後（送り終える前）から答えた形にし、同期待ちの印を出す。送り終えても、読み直す前から答えた形のまま
    @Test
    func pressShowsResultBeforeSendFinishes() async throws {
        let (service, store) = await makeStore()
        #expect(!isAnswered(store))
        service.holdsSending = true

        #expect(store.submit(answer) == .started)
        #expect(isAnswered(store))
        #expect(store.reflection(for: [target])?.phase == .sending)
        #expect(!store.needsAttention([target]))
        try await waitUntil { !service.performed.isEmpty }

        let fetches = service.fetchCount
        service.finishSending()
        try await waitUntil { store.reflection(for: [target])?.phase != .sending }
        #expect(store.reflection(for: [target])?.phase == .waiting(since: start))
        #expect(isAnswered(store))
        // 送った後の全体の読み直しはしない（受け付けは軽い確かめで待つ）
        #expect(service.fetchCount == fetches)
    }

    /// 取り消しの猶予の間も答えた形にし、取り消したら元に戻す
    @Test
    func undoRevertsPendingIntent() async {
        let (_, store) = await makeStore()
        store.enqueue(answer, message: "回答")
        #expect(isAnswered(store))
        store.undo()
        #expect(!isAnswered(store))
        #expect(store.reflection(for: [target]) == nil)
    }

    /// 送れなかったら元に戻し、帯で知らせる（もう一度送れる）
    @Test
    func failedSendReverts() async throws {
        let (service, store) = await makeStore()
        service.performError = ClientServiceError(message: "通信できませんでした")
        #expect(store.submit(answer) == .started)
        #expect(isAnswered(store))
        try await waitUntil { store.sendFailure != nil }
        #expect(!isAnswered(store))
        #expect(store.sendFailure == ClientStore.SendFailure(intent: answer, message: "通信できませんでした"))
        #expect(store.reflection(for: [target]) == nil)

        service.performError = nil
        await store.retryFailedSend()
        #expect(isAnswered(store))
    }

    /// 司令塔が断ったら元に戻し、その場（対象）に理由を出す
    @Test
    func rejectionReverts() async throws {
        let (service, store) = await makeStore()
        await store.send(answer)
        #expect(isAnswered(store))
        service.consumeWaiting(as: .rejected(at: start, reason: "質問の版が古い"))
        await store.refresh()
        #expect(!isAnswered(store))
        #expect(store.needsAttention([target]))
        #expect(store.rejections.map(\.reason) == ["質問の版が古い"])
    }

    /// 同じ対象への操作は、司令塔が受け付けるまで送らない（シートは理由を出して残る）
    @Test
    func submitIsBlockedWhileSameTargetIsSyncing() async {
        let (service, store) = await makeStore()
        await store.send(answer)
        let other = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "b", note: "")
        #expect(store.submit(other) == .blocked("回答の同期を待っています。司令塔が受け付けてから操作してください"))
        // シートの中で出すので、帯には出さない
        #expect(store.sendFailure == nil)
        #expect(service.performed == [answer])
    }

    // MARK: 送る順

    /// 押した順に送る（前に押した操作を送り終えるまで、後の操作は送らない）。どちらも押した直後から済んだ形
    @Test
    func sendsInPressedOrder() async throws {
        let (service, store) = await makeStore()
        service.holdsSending = true
        let pause = HumanIntent.pause(epicID: "tsundoku-search")
        #expect(store.submit(answer) == .started)
        #expect(store.submit(pause) == .started)
        try await waitUntil { !service.performed.isEmpty }
        try await Task.sleep(for: .milliseconds(20))
        #expect(service.performed == [answer])
        #expect(store.isReflecting(pause))

        service.finishSending()
        try await waitUntil { service.performed.count == 2 }
        #expect(service.performed == [answer, pause])
        service.finishSending()
    }

    // MARK: 受け付けの確かめ

    /// 司令塔の受け取りを待つ間だけ、受け付けの記録を確かめ、見つけたら全体を読み直して同期待ちを消す
    @Test
    func watchesReceiptAndRereads() async throws {
        let (service, store) = await makeStore()
        await store.send(answer)
        try await waitUntil { !service.receiptChecks.isEmpty }
        #expect(Set(service.receiptChecks) == ["n1"])
        #expect(store.isReflecting([target]))

        service.consumeWaiting(as: .accepted(at: start))
        try await waitUntil { store.reflection(for: [target]) == nil }
        #expect(store.reflection(for: [target]) == nil)
        #expect(isAnswered(store))
        // 待つものが無くなったら、確かめるのをやめる
        let checks = service.receiptChecks.count
        try await Task.sleep(for: .milliseconds(30))
        #expect(service.receiptChecks.count == checks)
    }

    /// GitHub の上限に当たったら、言われた間は確かめない
    @Test
    func receiptCheckPausesOnRateLimit() async throws {
        let clock = Clock(start)
        let (service, store) = await makeStore(clock: clock)
        service.receiptError = ClientServiceError(message: "上限", retryAfter: .seconds(60))
        await store.send(answer)
        try await waitUntil { !service.receiptChecks.isEmpty }
        try await Task.sleep(for: .milliseconds(30))
        #expect(service.receiptChecks.count == 1)

        service.receiptError = nil
        clock.now += 61
        try await waitUntil { service.receiptChecks.count > 1 }
        #expect(service.receiptChecks.count > 1)
    }

    /// 受け取りが遅い（`stallThreshold` を過ぎた）意図は確かめず、ふだんの取り直しに任せる
    @Test
    func receiptCheckStopsAfterStallThreshold() async throws {
        let clock = Clock(start)
        let (service, store) = await makeStore(clock: clock)
        await store.send(answer)
        clock.now += store.stallThreshold + 1
        try await Task.sleep(for: .milliseconds(30))
        let checks = service.receiptChecks.count
        try await Task.sleep(for: .milliseconds(30))
        #expect(service.receiptChecks.count == checks)
        #expect(store.needsAttention([target]))
    }
}
