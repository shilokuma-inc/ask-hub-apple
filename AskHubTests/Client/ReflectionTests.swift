@testable import AskHub
import Foundation
import Testing

/// 送った意図が反映されるまでの出し方: 操作した対象ごとの反映中、同じ対象への二重の操作を断ること、
/// 断られたときの理由、司令塔がしばらく受け取らないときの知らせ
@MainActor
struct ReflectionTests {
    /// 送った意図を、状態リポジトリと同じく対象ごとの受け取り待ちの記録として置く窓口（まとめて OK はカードごとの記録になる）
    private final class FakeService: ClientService {
        var refreshInterval: Duration = .seconds(60)
        var snapshot: ClientSnapshot
        var performed: [HumanIntent] = []
        var fetchCount = 0
        /// true の間は、`finishSending()` を呼ぶまで送り終わらない
        var holdsSending = false
        /// true の間は、`finishFetching()` を呼ぶまで読み終わらない（読み始めた時点の中身を返す）
        var holdsFetching = false
        /// true なら、複数の意図になる操作を、最初の意図だけ書いて失敗させる（書けた分の控えを添える）
        var failsAfterFirstIntent = false
        private var sendingWaiters: [CheckedContinuation<Void, Never>] = []
        private var fetchingWaiters: [CheckedContinuation<Void, Never>] = []
        private var nextID = 0
        let now: Date

        init(snapshot: ClientSnapshot, now: Date) {
            self.snapshot = snapshot
            self.now = now
        }

        func fetchSnapshot() async throws -> ClientSnapshot {
            fetchCount += 1
            let captured = snapshot
            if holdsFetching {
                await withCheckedContinuation { fetchingWaiters.append($0) }
            }
            return captured
        }

        func perform(_ intent: HumanIntent) async throws -> SendReceipt {
            performed.append(intent)
            if holdsSending {
                await withCheckedContinuation { sendingWaiters.append($0) }
            }
            let targets = failsAfterFirstIntent ? Array(intent.targets.prefix(1)) : intent.targets
            let sent = targets.map { target in
                nextID += 1
                let id = "intent-\(nextID)"
                let status = SentIntentStatus(id: id, title: intent.label, sentAt: now, state: .waiting, target: target)
                snapshot.sentIntents.insert(status, at: 0)
                return SendReceipt.Sent(id: id, target: target)
            }
            if failsAfterFirstIntent {
                throw ClientServiceError(message: "通信できませんでした", sentBeforeFailure: SendReceipt(sent: sent))
            }
            return SendReceipt(sent: sent)
        }

        func lastSend(of intent: HumanIntent) -> SentRecord? {
            nil
        }

        func finishSending() {
            sendingWaiters.forEach { $0.resume() }
            sendingWaiters = []
        }

        func finishFetching() {
            fetchingWaiters.forEach { $0.resume() }
            fetchingWaiters = []
        }

        /// 司令塔が受け取り待ちの意図をすべて処理した
        func consumeWaiting(as state: SentIntentStatus.State) {
            for index in snapshot.sentIntents.indices where snapshot.sentIntents[index].state == .waiting {
                snapshot.sentIntents[index].state = state
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

    private static let epicID = "tsundoku-search"
    private static let head = "9f3c2e1a7b"
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private var merge: HumanIntent {
        .merge(epicID: Self.epicID, headCommit: Self.head)
    }

    private var instruct: HumanIntent {
        .instructFinal(epicID: Self.epicID, headCommit: Self.head, instruction: "ボタンの色を戻して")
    }

    /// 時計を `start` に止めたストア（猶予は長くし、取り消しを確かめられるようにする）
    private func makeStore() async -> (FakeService, ClientStore) {
        let service = FakeService(snapshot: DemoScenario.standard.snapshot(now: start), now: start)
        let store = ClientStore(service: service, undoDelay: .seconds(60), now: { [start] in start })
        await store.refresh()
        return (service, store)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: 反映中の出し方

    /// 送っている間・司令塔の受け取り待ちの間は、対象に反映中を出す。受け付けたら読み直して、反映されたら消す
    @Test
    func showsReflectingFromSendUntilReread() async throws {
        let (service, store) = await makeStore()
        let target = IntentTarget.finalPullRequest(epicID: Self.epicID)
        #expect(store.reflection(for: [target]) == nil)

        service.holdsSending = true
        let sending = Task { await store.send(merge) }
        try await waitUntil { !service.performed.isEmpty }
        // 押した直後（GitHub に書いている間）から反映中で、同じ対象の操作は押せない
        #expect(store.reflection(for: [target]) == Reflection(label: "マージの承認", phase: .sending))
        #expect(store.isReflecting(instruct))
        service.finishSending()
        guard case .sent = await sending.value else {
            Issue.record("マージの承認を送れていない")
            return
        }
        #expect(store.reflection(for: [target]) == Reflection(label: "マージの承認", phase: .waiting(since: start)))
        // ほかの対象は普段どおり
        #expect(!store.isReflecting(.pause(epicID: Self.epicID)))

        // 受け付けを見つけたら、状態が反映されるよう続けてもう一度読み、反映中を消す
        service.consumeWaiting(as: .accepted(at: start))
        let fetches = service.fetchCount
        await store.refresh()
        #expect(service.fetchCount == fetches + 2)
        #expect(store.reflection(for: [target]) == nil)
        #expect(!store.isReflecting(instruct))
    }

    /// 前の起動で送って受け取り待ちの意図も、読んだ送った意図の一覧から反映中として出す。断られたら知らせる
    @Test
    func reflectsIntentSentBeforeLaunch() async {
        let clock = Clock(start)
        var snapshot = DemoScenario.standard.snapshot(now: start)
        let target = IntentTarget.goal(epicID: "budget-limit")
        let sentAt = start.addingTimeInterval(-5 * 60)
        snapshot.sentIntents = [SentIntentStatus(id: "old-1", title: "開始 · 月の上限の通知", sentAt: sentAt, state: .waiting, target: target)]
        let service = FakeService(snapshot: snapshot, now: start)
        let store = ClientStore(service: service, now: { clock.now })
        await store.refresh()
        #expect(store.reflection(for: [target]) == Reflection(label: "開始 · 月の上限の通知", phase: .waiting(since: sentAt)))
        #expect(store.isReflecting(.start(epicID: "budget-limit", macID: DemoData.macMiniID)))

        service.snapshot.sentIntents[0].state = .rejected(at: start, reason: "ゴールの版が古い")
        await store.refresh()
        #expect(store.rejections.map(\.message) == ["開始 · 月の上限の通知を受け付けませんでした"])
        #expect(store.reflection(for: [target])?.isPending == false)
    }

    /// 後に始めた読み込みが先に終わったら、先に始めた読み込みの古い中身で上書きしない
    @Test
    func olderReadDoesNotOverwriteNewer() async throws {
        let (service, store) = await makeStore()
        service.holdsFetching = true
        let older = Task { await store.refresh() }
        try await waitUntil { service.fetchCount == 2 }
        service.holdsFetching = false
        service.snapshot.sentIntents = [SentIntentStatus(id: "n1", title: "一時停止", sentAt: start, state: .waiting, target: nil)]
        await store.refresh()
        #expect(store.snapshot?.sentIntents.map(\.id) == ["n1"])
        service.finishFetching()
        await older.value
        #expect(store.snapshot?.sentIntents.map(\.id) == ["n1"])
    }

    // MARK: 二重の操作を断る

    /// 同じ対象への操作が反映されるまでは、ほかの操作も送らない（ほかの対象は送れる）。反映されたら送れる
    @Test
    func refusesOtherOperationOnSameTargetUntilReflected() async {
        let (service, store) = await makeStore()
        await store.send(merge)
        #expect(await store.send(instruct) == .failed("マージの承認を反映しています。反映されてから操作してください"))
        #expect(store.sendFailure?.intent == instruct)
        #expect(service.performed == [merge])

        guard case .sent = await store.send(.pause(epicID: Self.epicID)) else {
            Issue.record("ほかの対象への操作が送れていない")
            return
        }

        service.consumeWaiting(as: .accepted(at: start))
        await store.refresh()
        guard case .sent = await store.send(instruct) else {
            Issue.record("反映された後に、最終 PR への指示を送れていない")
            return
        }
        #expect(service.performed == [merge, .pause(epicID: Self.epicID), instruct])
    }

    /// 答えを送ったカードは、取り消しの猶予の間も送った後も、反映されるまで山札から外す（まとめて OK は、OK にしたカードすべて）
    @Test
    func deckHidesCardsUntilReflected() async throws {
        let (service, store) = await makeStore()
        let scope = DeckScope.decisions(Self.epicID)
        let shown = store.deckCards(scope).compactMap { card -> DecisionCard.ID? in
            guard case .decision(let decision) = card.content else {
                return nil
            }
            return decision.id
        }
        #expect(shown.count >= 2)
        let acceptAll = HumanIntent.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.head, decisionIDs: shown)
        store.enqueue(acceptAll, message: "まとめて OK")
        #expect(store.deckCards(scope).isEmpty)
        store.undo()
        #expect(store.deckCards(scope).count == shown.count)

        await store.send(acceptAll)
        #expect(store.deckCards(scope).isEmpty)
        #expect(service.snapshot.sentIntents.filter { $0.state == .waiting }.count == shown.count)

        // 断られたら山札に戻し、その理由をカードの対象に出す
        service.consumeWaiting(as: .rejected(at: start, reason: "最終 PR の head が進んだ"))
        await store.refresh()
        let cards = store.deckCards(scope)
        #expect(cards.count == shown.count)
        let reflection = try #require(cards.first.flatMap { store.reflection(for: [$0.target]) })
        guard case .rejected(let rejection) = reflection.phase else {
            Issue.record("断られた理由がカードの対象に出ていない: \(reflection)")
            return
        }
        #expect(rejection.reason == "最終 PR の head が進んだ")
        // 1 つの操作から出たカードごとの意図が同じ理由で断られたら、知らせは 1 つにまとめる（どのカードにも出す）
        #expect(store.rejections.count == 1)
        #expect(Set(rejection.targets) == Set(acceptAll.targets))
    }

    // MARK: 断られたときの理由

    /// 断られたら反映中を外し、理由を対象と帯に閉じるまで出す。同じ対象にもう一度送ると、前の知らせは外す
    @Test
    func rejectionIsShownAtTargetUntilDismissedOrResent() async throws {
        let (service, store) = await makeStore()
        let answer = HumanIntent.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "a", note: "")
        let target = IntentTarget.question(epicID: "recipe-weekly", questionID: "Q3")
        await store.send(answer)
        service.consumeWaiting(as: .rejected(at: start, reason: "質問の版が古い"))
        await store.refresh()

        let reflection = try #require(store.reflection(for: [target]))
        #expect(!reflection.isPending)
        #expect(!store.isReflecting(answer))
        guard case .rejected(let rejection) = reflection.phase else {
            Issue.record("断られた理由が対象に出ていない: \(reflection)")
            return
        }
        #expect(rejection.message == "回答を受け付けませんでした")
        #expect(rejection.reason == "質問の版が古い")
        #expect(store.rejections == [rejection])

        // その場で閉じると、帯からも消える
        store.dismissRejection(rejection.id)
        #expect(store.reflection(for: [target]) == nil)
        #expect(store.rejections.isEmpty)

        // もう一度断られてから送り直すと、前の知らせは外して反映中にする
        await store.send(.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "b", note: ""))
        service.consumeWaiting(as: .rejected(at: start, reason: "質問の版が古い"))
        await store.refresh()
        #expect(store.rejections.count == 1)
        await store.send(.answer(epicID: "recipe-weekly", questionID: "Q3", optionID: "c", note: ""))
        #expect(store.rejections.isEmpty)
        #expect(store.reflection(for: [target])?.isPending == true)
    }
}

// MARK: - 追跡と文言

extension ReflectionTests {
    /// 受け付けた記録を見つけた読み込みでは、状態がまだ書き換わる前のことがあるので、その後に始めた読み込みが終わるまで反映中にする
    @Test
    func acceptedStaysUntilLaterRead() {
        var tracker = ReflectionTracker()
        let intent = HumanIntent.pause(epicID: Self.epicID)
        let target = IntentTarget.epicControl(epicID: Self.epicID)
        let sendingID = tracker.beginSending(intent)
        tracker.finishSending(sendingID, receipt: SendReceipt(intentIDs: ["n1"]), announces: true, at: start)
        var snapshot = DemoScenario.standard.snapshot(now: start)
        snapshot.sentIntents = [SentIntentStatus(id: "n1", title: "一時停止", sentAt: start, state: .waiting, target: target)]
        #expect(tracker.receive(snapshot, generation: 1, latestStarted: 1, now: start, trackingWindow: 600) == ReflectionTracker.Receipts())
        #expect(tracker.reflection(matching: { $0 == target }, pending: nil)?.phase == .waiting(since: start))

        // 読み込み 2 で受け付けを見つけたとき、読み込み 3 はもう始めてあった（状態を書き換える前に読んだかもしれない）
        snapshot.sentIntents[0].state = .accepted(at: start)
        let receipts = tracker.receive(snapshot, generation: 2, latestStarted: 3, now: start, trackingWindow: 600)
        #expect(receipts == ReflectionTracker.Receipts(acceptedAnnounced: [intent], needsReread: true))
        #expect(tracker.reflection(matching: { $0 == target }, pending: nil)?.phase == .accepted)
        _ = tracker.receive(snapshot, generation: 3, latestStarted: 4, now: start, trackingWindow: 600)
        #expect(tracker.reflection(matching: { $0 == target }, pending: nil)?.phase == .accepted)

        // 受け付けを見つけた後に始めた読み込み 4 が終わったら、反映されたとして消す
        #expect(tracker.receive(snapshot, generation: 4, latestStarted: 4, now: start, trackingWindow: 600) == ReflectionTracker.Receipts())
        #expect(tracker.reflection(matching: { $0 == target }, pending: nil) == nil)
    }

    /// まとめて OK の意図の一部だけが断られたら、断られた意図で答えたカードにだけ理由を出す（受け付けたカードには出さない）
    @Test
    func tracksEachIntentOfOperationSeparately() {
        var tracker = ReflectionTracker()
        let first = IntentTarget.decision(epicID: Self.epicID, decisionID: "d3")
        let second = IntentTarget.decision(epicID: Self.epicID, decisionID: "d4")
        let acceptAll = HumanIntent.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.head, decisionIDs: ["d3", "d4"])
        let sendingID = tracker.beginSending(acceptAll)
        let receipt = SendReceipt(sent: [SendReceipt.Sent(id: "n1", target: first), SendReceipt.Sent(id: "n2", target: second)])
        tracker.finishSending(sendingID, receipt: receipt, announces: true, at: start)
        var snapshot = DemoScenario.standard.snapshot(now: start)
        snapshot.sentIntents = [
            SentIntentStatus(id: "n2", title: "判断への回答", sentAt: start, state: .rejected(at: start, reason: "答え済み"), target: second),
            SentIntentStatus(id: "n1", title: "判断への回答", sentAt: start, state: .accepted(at: start), target: first)
        ]
        _ = tracker.receive(snapshot, generation: 1, latestStarted: 1, now: start, trackingWindow: 600)
        #expect(tracker.reflection(matching: { $0 == first }, pending: nil)?.phase == .accepted)
        guard case .rejected(let rejection)? = tracker.reflection(matching: { $0 == second }, pending: nil)?.phase else {
            Issue.record("断られた意図で答えたカードに理由が出ていない")
            return
        }
        #expect(rejection.targets == [second])
    }

    /// 前の起動で送った受け取り待ちの意図が、読み込みで一時的に見つからなくても、しばらくは反映中のままにし、後で断られたら知らせる
    @Test
    func keepsPreviousWaitingWhileMissing() async {
        let clock = Clock(start)
        var snapshot = DemoScenario.standard.snapshot(now: start)
        let target = IntentTarget.epicControl(epicID: "rain-draft")
        snapshot.sentIntents = [SentIntentStatus(id: "old-1", title: "取り下げ", sentAt: start, state: .waiting, target: target)]
        let service = FakeService(snapshot: snapshot, now: start)
        let store = ClientStore(service: service, now: { clock.now })
        await store.refresh()
        let waiting = service.snapshot.sentIntents
        service.snapshot.sentIntents = []
        await store.refresh()
        #expect(store.isReflecting([target]))

        service.snapshot.sentIntents = waiting
        service.snapshot.sentIntents[0].state = .rejected(at: start, reason: "開始した epic は取り下げられない")
        await store.refresh()
        #expect(store.rejections.map(\.reason) == ["開始した epic は取り下げられない"])

        // 待つ間を過ぎても見つからなければ忘れる
        service.snapshot.sentIntents = [SentIntentStatus(id: "old-2", title: "一時停止", sentAt: start, state: .waiting, target: target)]
        await store.refresh()
        service.snapshot.sentIntents = []
        await store.refresh()
        clock.now += ClientStore.receiptTrackingWindow
        await store.refresh()
        #expect(!store.isReflecting([target]))
    }

    /// まとめて OK の途中で失敗したら、書けた分は反映中として追い、同じ操作をもう一度送れる（窓口が残りだけを送る）
    @Test
    func partialFailureKeepsSentIntentsAndAllowsRetry() async {
        let (service, store) = await makeStore()
        let acceptAll = HumanIntent.acceptAllDecisions(epicID: Self.epicID, headCommit: Self.head, decisionIDs: ["d3", "d4"])
        service.failsAfterFirstIntent = true
        #expect(await store.send(acceptAll) == .failed("通信できませんでした"))
        #expect(store.isReflecting([.decision(epicID: Self.epicID, decisionID: "d3")]))
        #expect(!store.isReflecting([.decision(epicID: Self.epicID, decisionID: "d4")]))

        service.failsAfterFirstIntent = false
        guard case .sent = await store.send(acceptAll) else {
            Issue.record("途中で失敗したまとめて OK を、もう一度送れていない")
            return
        }
        #expect(service.performed == [acceptAll, acceptAll])
        // ほかの操作は、これまでどおり反映されるまで止める
        let answer = HumanIntent.respondToDecision(epicID: Self.epicID, decisionID: "d3", headCommit: Self.head, reply: .accept)
        guard case .failed = await store.send(answer) else {
            Issue.record("反映を待つカードへのほかの答えを止めていない")
            return
        }
    }

    // MARK: 司令塔が受け取らないときの知らせ

    /// 司令塔が受け取らないまま時間がたったら、司令塔の生きている印と合わせて知らせる
    @Test
    func stalledReflectionMentionsCommanderHeartbeat() {
        let now = start
        let waiting = Reflection(label: "マージの承認", phase: .waiting(since: now.addingTimeInterval(-60)))
        #expect(!waiting.isStalled(now: now, threshold: ClientStore.defaultStallThreshold))
        let fresh = ReflectionMessage.make(waiting, now: now, stallThreshold: ClientStore.defaultStallThreshold, commanderSeenAt: now)
        #expect(fresh.tone == .progress)
        #expect(fresh.title == "反映中")
        #expect(fresh.detail.hasPrefix("マージの承認を司令塔が受け取るのを待っています"))

        let stalled = Reflection(label: "マージの承認", phase: .waiting(since: now.addingTimeInterval(-4 * 60)))
        #expect(stalled.isStalled(now: now, threshold: ClientStore.defaultStallThreshold))
        let unknown = ReflectionMessage.make(stalled, now: now, stallThreshold: ClientStore.defaultStallThreshold, commanderSeenAt: nil)
        #expect(unknown.tone == .stalled)
        #expect(unknown.badge == "受け取り待ち")
        #expect(unknown.title.hasPrefix("司令塔がまだ受け取っていません"))
        #expect(unknown.detail.hasPrefix("司令塔の生きている印を読めていません"))

        // 生きている印が古ければ、止まっているかもしれないと書く
        let silent = now.addingTimeInterval(-20 * 60)
        let stopped = ReflectionMessage.make(stalled, now: now, stallThreshold: ClientStore.defaultStallThreshold, commanderSeenAt: silent)
        #expect(stopped.detail.contains("止まっているかもしれません"))
        #expect(stopped.detail.hasSuffix("動き出せば、送ったマージの承認を受け取ります"))

        // 印が新しければ、混んでいるか止まったばかりと書く
        let recent = now.addingTimeInterval(-2 * 60)
        let busy = ReflectionMessage.make(stalled, now: now, stallThreshold: ClientStore.defaultStallThreshold, commanderSeenAt: recent)
        #expect(busy.detail.contains("混んでいるか、止まったばかりかもしれません"))
    }

    /// 送っている・受け付けた・断られたの文言
    @Test
    func messagesForEachPhase() {
        let sending = ReflectionMessage.make(
            Reflection(label: "開始", phase: .sending),
            now: start,
            stallThreshold: 180,
            commanderSeenAt: nil
        )
        #expect(sending == ReflectionMessage(title: "送っています", detail: "開始を送っています", tone: .progress, badge: "送信中"))

        let accepted = ReflectionMessage.make(
            Reflection(label: "開始", phase: .accepted),
            now: start,
            stallThreshold: 180,
            commanderSeenAt: nil
        )
        #expect(accepted.detail == "開始を受け付けました。画面に反映しています")

        let rejection = ReflectionTracker.Rejection(targets: [.goal(epicID: "e1")], label: "開始", reason: "Mac がオフライン")
        let rejected = ReflectionMessage.make(
            Reflection(label: "開始", phase: .rejected(rejection)),
            now: start,
            stallThreshold: 180,
            commanderSeenAt: nil
        )
        #expect(rejected.tone == .rejected)
        #expect(rejected.title == "開始を受け付けませんでした")
        #expect(rejected.detail == "Mac がオフライン")
        #expect(rejected.rejectionID == rejection.id)
    }

    // MARK: 対象の決め方

    /// 意図の対象。まとめて OK は OK にするカードそれぞれ、epic の操作は 1 つの対象にまとめる
    @Test
    func intentTargets() {
        let acceptAll = HumanIntent.acceptAllDecisions(epicID: "e1", headCommit: nil, decisionIDs: ["d1", "d2"])
        #expect(acceptAll.targets == [.decision(epicID: "e1", decisionID: "d1"), .decision(epicID: "e1", decisionID: "d2")])
        let controls: [HumanIntent] = [
            .pause(epicID: "e1"), .resume(epicID: "e1"), .handOver(epicID: "e1", macID: "m"), .discard(epicID: "e1")
        ]
        #expect(Set(controls.flatMap(\.targets)) == [.epicControl(epicID: "e1")])
        #expect(HumanIntent.start(epicID: "e1", macID: "m").targets == HumanIntent.reviseGoal(epicID: "e1", request: "").targets)
        #expect(merge.targets == instruct.targets)
        #expect(HumanIntent.request(repositoryID: "o/r", summary: "s", body: "").targets.isEmpty)
        #expect(IntentTarget.repository("o/r").epicID == nil)
    }
}
