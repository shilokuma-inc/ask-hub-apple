@testable import AskHub
import Foundation
import Testing

/// ストアの取得のライフサイクルと、取り消しの猶予つきの送信
@MainActor
struct ClientStoreTests {
    /// 取得と送信を記録し、失敗を差し込める窓口
    private final class FakeService: ClientService {
        var refreshInterval: Duration = .seconds(60)
        var snapshot: ClientSnapshot?
        var fetchError: ClientServiceError?
        var performed: [HumanIntent] = []

        func fetchSnapshot() async throws -> ClientSnapshot {
            if let fetchError {
                throw fetchError
            }
            guard let snapshot else {
                throw ClientServiceError(message: "空")
            }
            return snapshot
        }

        func perform(_ intent: HumanIntent) async throws {
            performed.append(intent)
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
}
