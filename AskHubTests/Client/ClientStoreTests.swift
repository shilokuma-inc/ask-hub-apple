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
        /// 送った意図の控えに入れる id（司令塔が受け付けたかを確かめる）
        var receiptIntentID: String?
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
            return SendReceipt(requestedEpicID: intent.isRequest ? "request-1" : nil, intentID: receiptIntentID)
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
        #expect(store.deckCards(.questions("recipe-weekly")).count == 1)
        let intent = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: "")
        store.enqueue(intent, message: "回答")
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

    /// 送れただけでは帯を出さず（画面は送った結果の形になる）、司令塔が受け付けたら帯で知らせ、しばらくしたら消す
    @Test
    func announcesAcceptedIntentAndHidesNoticeLater() async throws {
        let service = FakeService()
        var snapshot = DemoScenario.standard.snapshot(now: now)
        snapshot.sentIntents = [SentIntentStatus(id: "nonce-1", title: "依頼", sentAt: now, state: .waiting)]
        service.snapshot = snapshot
        service.receiptIntentID = "nonce-1"
        let store = ClientStore(service: service, noticeDuration: .milliseconds(20), now: { [now] in now })
        let intent = HumanIntent.request(repositoryID: "example/memo-ios", summary: "メモ並べ替え", body: "")

        #expect(await store.send(intent) == .sent(SendReceipt(requestedEpicID: "request-1", intentID: "nonce-1")))
        #expect(store.notice == nil)
        service.snapshot?.sentIntents[0].state = .accepted(at: now)
        await store.refresh()
        #expect(store.notice?.message == "依頼「メモ並べ替え」を受け付けました")
        #expect(store.notice?.detail == "司令塔が受け取りました")
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
        #expect(service.performed.last == failed)
    }

    /// テストで進める時計
    private final class Clock {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }
    }

    /// 開始を送り、司令塔の受け付けを待っている窓口とストア
    private func startWaitingForCommander(
        noticeDuration: Duration = .seconds(5),
        clock: Clock? = nil
    ) async -> (FakeService, ClientStore) {
        let service = FakeService()
        var snapshot = DemoScenario.standard.snapshot(now: now)
        snapshot.sentIntents = [SentIntentStatus(id: "nonce-1", title: "開始", sentAt: now, state: .waiting)]
        service.snapshot = snapshot
        service.receiptIntentID = "nonce-1"
        let clock = clock ?? Clock(now)
        let store = ClientStore(service: service, noticeDuration: noticeDuration, now: { clock.now })
        #expect(await store.send(.start(epicID: "budget-limit", macID: DemoData.macMiniID)) == .sent(SendReceipt(intentID: "nonce-1")))
        // 送れただけでは帯を出さない（画面は開始した形になり、同期待ちの印だけを出す）
        #expect(store.notice == nil)
        return (service, store)
    }

    /// 開始を送った後、司令塔が受け付けたら、どの Mac で開始したかを帯で知らせる（知らせるのは 1 度だけ）
    @Test
    func announcesStartAcceptedByCommander() async {
        let (service, store) = await startWaitingForCommander()
        await store.refresh()
        #expect(store.notice == nil)

        service.snapshot?.sentIntents[0].state = .accepted(at: now)
        await store.refresh()
        #expect(store.notice?.message == "Mac mini で開始しました")
        #expect(store.notice?.detail == "作業場所の用意から進めます")
        #expect(store.rejections.isEmpty)

        store.dismissNotice()
        await store.refresh()
        #expect(store.notice == nil)
    }

    /// 司令塔が受け付けなかったら、理由を出し、ほかの帯が出ても閉じるまで消さない。重なったら 1 つずつ出す
    @Test
    func showsRejectionsUntilDismissed() async throws {
        let (service, store) = await startWaitingForCommander(noticeDuration: .milliseconds(20))
        service.receiptIntentID = "nonce-2"
        service.snapshot?.sentIntents.insert(SentIntentStatus(id: "nonce-2", title: "取り下げ", sentAt: now, state: .waiting), at: 0)
        await store.send(.discard(epicID: "rain-draft"))
        service.snapshot?.sentIntents[0].state = .rejected(at: now, reason: "epic はもう始まっている")
        service.snapshot?.sentIntents[1].state = .rejected(at: now, reason: "Mac mac-mini がオフライン")
        await store.refresh()
        #expect(store.rejections.map(\.message) == ["開始を受け付けませんでした", "取り下げを受け付けませんでした"])
        #expect(store.rejections.first?.detail == "Mac mac-mini がオフライン")

        // 送れたことの帯は消えても、断られた知らせは残る
        service.receiptIntentID = nil
        await store.send(.addRepository(repositoryID: "example/memo-ios"))
        for _ in 0..<100 where store.notice != nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(store.notice == nil)
        #expect(store.rejections.count == 2)
        store.dismissRejection()
        #expect(store.rejections.map(\.detail) == ["epic はもう始まっている"])
        store.dismissRejection()
        #expect(store.rejections.isEmpty)
    }

    /// 送った意図が読んだ中に一時的に見つからなくても、しばらくは受け付けを待ち続ける
    @Test
    func keepsWaitingWhileSentIntentIsMissing() async {
        let clock = Clock(now)
        let (service, store) = await startWaitingForCommander(clock: clock)
        let sent = service.snapshot?.sentIntents ?? []
        service.snapshot?.sentIntents = []
        await store.refresh()
        service.snapshot?.sentIntents = sent
        service.snapshot?.sentIntents[0].state = .accepted(at: now)
        await store.refresh()
        #expect(store.notice?.message == "Mac mini で開始しました")

        // 待つ間を過ぎて見つからない意図は忘れる
        service.receiptIntentID = "nonce-2"
        await store.send(.discard(epicID: "rain-draft"))
        clock.now += ClientStore.receiptTrackingWindow
        await store.refresh()
        service.snapshot?.sentIntents.insert(
            SentIntentStatus(id: "nonce-2", title: "取り下げ", sentAt: now, state: .rejected(at: now, reason: "遅れて見つかった")),
            at: 0
        )
        await store.refresh()
        #expect(store.rejections.isEmpty)
    }
}

// MARK: - 取り直しの間隔

extension ClientStoreTests {
    /// GitHub の上限に当たったら、言われた時刻まで自動の取り直しを休み、戻る時刻を出す
    @Test
    func pausesAutoRefreshUntilRateLimitResets() async throws {
        let clock = Clock(now)
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service) { clock.now }
        await store.refresh()
        service.fetchError = ClientServiceError(message: "GitHub の上限に達しました", retryAfter: .seconds(600))
        await store.refresh()
        let ended = try #require(store.lastRefreshEndedAt)
        let until = now.addingTimeInterval(600)
        #expect(store.refreshPausedUntil == until)
        #expect(store.isRefreshPaused)
        #expect(store.refreshFailure == "GitHub の上限に当たりました。\(RelativeTime.clock(until)) に戻ります")
        // 間隔（60 秒）が空いても、戻る時刻まで待つ。もう一度読むボタンは出さない
        #expect(store.delayBeforeAutoRefresh(relaxed: false, at: ended + .seconds(60)) == .seconds(600))
        let status = ConnectionStatusView.status(store: store)
        #expect(status.title == "GitHub の上限に当たりました")
        #expect(status.detail == "\(RelativeTime.clock(until)) に戻ります。\(RelativeTime.clock(now)) の内容です")
        #expect(!status.offersRetry)

        // 戻ったら読み、読めたら休みを解く
        clock.now = until
        #expect(!store.isRefreshPaused)
        #expect(store.delayBeforeAutoRefresh(relaxed: false, at: ended + .seconds(60)) == .zero)
        service.fetchError = nil
        await store.refresh()
        #expect(store.refreshPausedUntil == nil)
        #expect(store.refreshFailure == nil)
    }

    /// 一度も読めないうちに上限に当たっても、戻る時刻を出す
    @Test
    func showsResetTimeWhenRateLimitedBeforeFirstLoad() async {
        let service = FakeService()
        service.fetchError = ClientServiceError(message: "GitHub の上限に達しました", retryAfter: .seconds(90))
        let store = ClientStore(service: service) { now }
        await store.refresh()
        let until = now.addingTimeInterval(90)
        #expect(store.phase == .failed("GitHub の上限に当たりました。\(RelativeTime.clock(until)) に戻ります"))
        #expect(ConnectionStatusView.status(store: store).title == "GitHub の上限に当たりました")
    }

    /// 前の読み込みを終えてから間隔を空ける。Mac で前面でないときは 2 分に延ばす（時計が止まっていても、経過時間で回る）
    @Test
    func relaxesAutoRefreshWhenNotFrontmost() async throws {
        let service = FakeService()
        service.snapshot = DemoScenario.standard.snapshot(now: now)
        let store = ClientStore(service: service) { now }
        // まだ読んでいなければ、すぐ読む
        #expect(store.delayBeforeAutoRefresh(relaxed: true) == .zero)
        await store.refresh()
        let ended = try #require(store.lastRefreshEndedAt)
        #expect(store.delayBeforeAutoRefresh(relaxed: false, at: ended) == .seconds(60))
        #expect(store.delayBeforeAutoRefresh(relaxed: true, at: ended) == ClientStore.relaxedRefreshInterval)
        // 前面に戻って回し直しても、間隔が空いていなければすぐには読まない
        #expect(store.delayBeforeAutoRefresh(relaxed: false, at: ended + .seconds(50)) == .seconds(10))
        #expect(store.delayBeforeAutoRefresh(relaxed: false, at: ended + .seconds(70)) == .seconds(-10))
        #expect(store.delayBeforeAutoRefresh(relaxed: true, at: ended + .seconds(70)) == .seconds(50))
    }

    /// GitHub の REST の残りを接続の行に小さく添え、少なくなったら警告にして、取り直しの間隔を延ばす
    @Test
    func showsGitHubQuotaAndRelaxesWhenLow() async throws {
        let service = FakeService()
        var snapshot = DemoScenario.standard.snapshot(now: now)
        service.snapshot = snapshot
        let store = ClientStore(service: service) { now }
        await store.refresh()
        let ended = try #require(store.lastRefreshEndedAt)
        let status = ConnectionStatusView.status(store: store)
        #expect(status.title == "Mac 2 / 3 台がオンライン")
        #expect(status.detail == "\(RelativeTime.clock(now)) に確かめました · GitHub の残り 4,210 回")
        #expect(store.delayBeforeAutoRefresh(relaxed: false, at: ended) == .seconds(60))

        snapshot.updateMac(DemoData.macMiniID) { $0.githubQuota?.remaining = 820 }
        service.snapshot = snapshot
        await store.refresh()
        let resetAt = try #require(snapshot.mac(DemoData.macMiniID)?.githubQuota?.resetAt)
        let low = ConnectionStatusView.status(store: store)
        #expect(low.title == "GitHub の残りが少なくなっています（820 回）")
        #expect(low.detail == "\(RelativeTime.clock(resetAt)) に戻ります。GitHub を多く使うものを止めてください")
        let lowEnded = try #require(store.lastRefreshEndedAt)
        #expect(store.delayBeforeAutoRefresh(relaxed: false, at: lowEnded) == ClientStore.relaxedRefreshInterval)
    }
}
