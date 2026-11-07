@testable import AskHub
import Foundation
import Testing

/// ストアの取得のライフサイクルと、取り消しの猶予つきの送信
@MainActor
struct ClientStoreTests {
    /// 取得と送信を記録し、失敗・送った記録・送り終わるまでの待ちを差し込める窓口
    private final class FakeService: ClientService {
        var refreshInterval: Duration = .seconds(60)
        var snapshot: ClientSnapshot?
        var fetchError: ClientServiceError?
        var performError: ClientServiceError?
        var performed: [HumanIntent] = []
        var sentRecords: [HumanIntent: SentRecord] = [:]
        /// true の間は、`finishSending()` を呼ぶまで送り終わらない
        var holdsSending = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func fetchSnapshot() async throws -> ClientSnapshot {
            if let fetchError {
                throw fetchError
            }
            guard let snapshot else {
                throw ClientServiceError(message: "空")
            }
            return snapshot
        }

        func perform(_ intent: HumanIntent) async throws -> SendReceipt {
            performed.append(intent)
            if holdsSending {
                await withCheckedContinuation { waiting.append($0) }
            }
            if let performError {
                throw performError
            }
            return SendReceipt(requestedEpicID: intent.isRequest ? "request-1" : nil)
        }

        func lastSend(of intent: HumanIntent) -> SentRecord? {
            sentRecords[intent]
        }

        func finishSending() {
            waiting.forEach { $0.resume() }
            waiting = []
        }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 一度も読めないときは失敗として出す
    @Test
    func showsFailureWhenNeverLoaded() async {
        let service = FakeService()
        service.fetchError = ClientServiceError(message: "接続できません")
        let store = ClientStore(service: service)
        await store.refresh()
        #expect(store.phase == .failed("接続できません"))
        #expect(store.snapshot == nil)
        #expect(store.inboxItems.isEmpty)
    }

    /// 取り直しに失敗しても前の内容を残して失敗を出す
    @Test
    func keepsSnapshotWhenRefreshFails() async {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service)
        await store.refresh()
        service.fetchError = ClientServiceError(message: "503")
        await store.refresh()
        #expect(store.phase == .loaded)
        #expect(store.snapshot != nil)
        #expect(store.refreshFailure == "503")
    }

    /// 猶予の間は送らずにカードを隠し取り消せる
    @Test
    func holdsIntentDuringUndoDelay() async {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service, undoDelay: .seconds(60))
        await store.refresh()
        let card = store.deckCards(.questions("recipe-weekly")).first
        let intent = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: "")
        store.enqueue(intent, message: "回答", itemID: card?.id)
        #expect(store.pending?.intent == intent)
        #expect(store.deckCards(.questions("recipe-weekly")).isEmpty)
        #expect(service.performed.isEmpty)

        store.undo()
        #expect(store.pending == nil)
        #expect(store.deckCards(.questions("recipe-weekly")).count == 1)
        #expect(service.performed.isEmpty)
    }

    /// 猶予が過ぎたら送る
    @Test
    func sendsAfterUndoDelay() async throws {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service, undoDelay: .milliseconds(10))
        await store.refresh()
        let intent = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: "")
        store.enqueue(intent, message: "回答")
        for _ in 0..<100 where service.performed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.performed == [intent])
        #expect(store.pending == nil)
    }

    /// 猶予の間に次を送ると前のものはすぐ送る
    @Test
    func sendsPreviousWhenNextIsQueued() async throws {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service, undoDelay: .seconds(60))
        await store.refresh()
        let first = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: "")
        let second = HumanIntent.answer(epicID: "habit-export", questionID: "Q2", optionID: "a", note: "")
        store.enqueue(first, message: "1")
        store.enqueue(second, message: "2")
        for _ in 0..<100 where service.performed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(service.performed == [first])
        #expect(store.pending?.intent == second)
    }

    // MARK: 二重に送らない

    /// 送っている途中の同じ意図は、重ねて送らない
    @Test
    func doesNotSendSameIntentWhileSending() async throws {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        service.holdsSending = true
        let store = ClientStore(service: service, now: { [now] in now })
        let intent = HumanIntent.request(repositoryID: "example/memo-ios", summary: "メモ並べ替え", body: "長押しで並べ替える")
        let first = Task { await store.send(intent) }
        for _ in 0..<100 where service.performed.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await store.send(intent) == .alreadySent)
        #expect(await store.send(intent) == .alreadySent)
        service.finishSending()
        #expect(await first.value == .sent(SendReceipt(requestedEpicID: "request-1")))
        #expect(service.performed == [intent])
    }

    /// 送ってあって司令塔がまだ受け取っていない同じ意図は、送り直さずに、送ってあることを知らせる
    @Test
    func doesNotResendIntentWaitingForCommander() async {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service, now: { [now] in now })
        let intent = HumanIntent.start(epicID: "rain-draft", macID: "mac-mini")
        service.sentRecords[intent] = SentRecord(sentAt: now.addingTimeInterval(-90), isWaiting: true)

        #expect(await store.send(intent) == .alreadySent)
        #expect(service.performed.isEmpty)
        #expect(store.notice?.message == "開始は送ってあります")
        #expect(store.notice?.detail == "司令塔が受け取るのを待っています")

        // 司令塔が受け取った後は、同じ意図をまた送れる
        service.sentRecords[intent] = SentRecord(sentAt: now.addingTimeInterval(-90), isWaiting: false)
        #expect(await store.send(intent) == .sent(SendReceipt()))
        #expect(service.performed == [intent])
    }

    /// 送れたら帯で知らせ、しばらくしたら消す
    @Test
    func announcesSentIntentAndHidesNoticeLater() async throws {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service, noticeDuration: .milliseconds(20), now: { [now] in now })
        let intent = HumanIntent.request(repositoryID: "example/memo-ios", summary: "メモ並べ替え", body: "")

        #expect(await store.send(intent) == .sent(SendReceipt(requestedEpicID: "request-1")))
        #expect(store.notice?.message == "依頼「メモ並べ替え」を送りました")
        #expect(store.notice?.detail == "司令塔が受け取るのを待っています")
        for _ in 0..<100 where store.notice != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.notice == nil)
    }

    /// 同じ内容の依頼は、1 分の間は送る前に確かめる。確かめたうえでなら、受け取り待ちでも送る
    @Test
    func recentlySentRequestIsConfirmedBeforeSending() async {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service, now: { [now] in now })
        let request = HumanIntent.request(repositoryID: "example/memo-ios", summary: "メモ並べ替え", body: "長押し")
        #expect(store.recentlySentRequest(request) == nil)

        let sentAt = now.addingTimeInterval(-30)
        service.sentRecords[request] = SentRecord(sentAt: sentAt, isWaiting: true)
        #expect(store.recentlySentRequest(request) == sentAt)
        #expect(await store.send(request) == .sent(SendReceipt(requestedEpicID: "request-1")))
        #expect(service.performed == [request])

        service.sentRecords[request] = SentRecord(sentAt: now.addingTimeInterval(-61), isWaiting: true)
        #expect(store.recentlySentRequest(request) == nil)
        // 依頼でない意図は確かめない（受け取り待ちなら送り直さない）
        let answer = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: "")
        service.sentRecords[answer] = SentRecord(sentAt: sentAt, isWaiting: true)
        #expect(store.recentlySentRequest(answer) == nil)
    }

    /// シートから送って失敗したら、帯には出さずに理由を返す
    @Test
    func sheetFailureIsReturnedWithoutBar() async {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        service.performError = ClientServiceError(message: "通信できませんでした")
        let store = ClientStore(service: service, now: { [now] in now })
        let intent = HumanIntent.addRepository(repositoryID: "example/memo-ios")

        #expect(await store.send(intent, reportsFailure: false) == .failed("通信できませんでした"))
        #expect(store.sendFailure == nil)
        #expect(store.notice == nil)
        #expect(await store.send(intent) == .failed("通信できませんでした"))
        #expect(store.sendFailure?.intent == intent)
    }

    /// ほかの意図を送れても、送れなかった意図の帯は、もう一度送れるように残す
    @Test
    func keepsFailureOfOtherIntent() async {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service, now: { [now] in now })
        let failed = HumanIntent.discard(epicID: "rain-draft")
        service.performError = ClientServiceError(message: "通信できませんでした")
        await store.send(failed)
        service.performError = nil

        await store.send(.start(epicID: "rain-draft", macID: "mac-mini"))
        #expect(store.sendFailure?.intent == failed)
        await store.retryFailedSend()
        #expect(store.sendFailure == nil)
        #expect(store.notice?.message == "取り下げを送りました")
    }
}
