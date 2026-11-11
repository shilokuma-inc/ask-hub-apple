import Foundation
import Observation

/// 画面が読む状態と、人の意図を送る操作をまとめたもの。
///
/// 取得のライフサイクル（読み込み中・失敗・前回の値を残す）はここだけで持ち、画面ごとにコピーしない。
/// 操作は押した時点で送った結果として画面に当て（済んだ形にして次の操作に進めるようにする）、司令塔が受け付けるまでは
/// 同じ対象への操作を止めて、行やカードの隅に小さな「同期待ち」の印だけを出す。送れなかった・断られたら元に戻す
@Observable
final class ClientStore {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        /// 一度も読めていない
        case failed(String)
    }

    /// 取り消しの猶予の間、送らずに持っている意図（対象は、送った扱いにして山札から外す）
    struct PendingIntent: Identifiable, Equatable {
        let id = UUID()
        let intent: HumanIntent
        /// 例: 献立メモ · 質問 Q3: 月曜の朝 9 時に固定
        let message: String
    }

    struct SendFailure: Equatable {
        let intent: HumanIntent
        let message: String
    }

    /// 送った結果。シートは、置けたら閉じ、失敗したら理由を出して残る
    enum SendResult: Equatable {
        case sent(SendReceipt)
        /// 同じ意図を送っている途中か、送ってあって司令塔がまだ受け取っていない。送り直さない
        case alreadySent
        case failed(String)
    }

    /// シートから送り始めた結果。送り始めたら（送ってあったときも）シートを閉じ、同じ対象への操作が同期を待っていて送れなければ理由を出して残る
    enum SubmitResult: Equatable {
        case started
        case alreadySent
        case blocked(String)
    }

    /// 送ってあることと、司令塔が受け付けたことを知らせる帯（しばらくしたら消す）。司令塔が断ったことは `rejections` で閉じるまで出す
    struct SendNotice: Identifiable, Equatable {
        let id = UUID()
        /// 例: 依頼「週ごとのまとめ」を受け付けました
        let message: String
        /// 送った後の見通し（状態リポジトリの「送った意図」・epic の履歴と同じ言い方にする）。断られたときは理由
        var detail = "司令塔が受け取るのを待っています"
    }

    /// 同じ内容の依頼を重ねて送る前に、確かめる間
    static let duplicateRequestWindow: TimeInterval = 60
    /// 送った意図が読んだ中に見つからない（読めなかった・新しい 20 件から外れた）とき、受け付けを待ち続ける間
    static let receiptTrackingWindow: TimeInterval = 10 * 60
    /// 司令塔は 30 秒ほどの周ごとに意図を受け取る。これより長く受け取らなければ、司令塔が動いていない可能性をその場に出す
    static let defaultStallThreshold: TimeInterval = 3 * 60
    /// 延ばした取り直しの間隔（Mac で前面でないとき）。GitHub の上限をほかのもの（司令塔・Claude のセッション）に残す
    static let relaxedRefreshInterval: Duration = .seconds(2 * 60)

    private(set) var snapshot: ClientSnapshot?
    private(set) var phase: Phase = .idle
    /// 前回の取り直しの失敗。スナップショットは前のものを残し、失敗したことを帯で出す
    private(set) var refreshFailure: String?
    /// GitHub の上限に当たって、自動の取り直しを休んでいる間の、戻る時刻（読めたら消す）
    private(set) var refreshPausedUntil: Date?
    /// 最後に読み込みを終えた時点。自動の取り直しの間隔は、ここからの経過時間で数える（`ClientStore+Refresh`。時計を止めたデモでも回るように）
    private(set) var lastRefreshEndedAt: ContinuousClock.Instant?
    private(set) var pending: PendingIntent?
    private(set) var sendFailure: SendFailure?
    private(set) var notice: SendNotice?
    /// 送った意図が画面に反映されるまでの様子（対象ごと）と、司令塔が断った知らせ
    private(set) var reflections = ReflectionTracker()
    /// 押したが、まだ送り終えていない意図（押した順。取り消しの猶予の間のものは `pending`）。送った結果として先に画面に当てる。
    /// 同じ意図は、送り終わるまで重ねて送らない
    private var unsent: [HumanIntent] = []
    /// 最後に送り始めた意図を送り終えるまで（押した順に送る）
    private var sendTail: Task<Void, Never>?
    /// 受け付けの記録を軽く確かめている間の Task。司令塔の受け取りを待つ意図が無くなったら終わる
    private var receiptWatch: Task<Void, Never>?
    /// GitHub の上限に当たったときに、受け付けの記録を確かめるのを休む時刻
    private var receiptCheckPausedUntil: Date?
    /// マージ中の epic を、マージ済みになるまで短い間隔で読み直している様子（`ClientStore+MergeWatch`）
    @ObservationIgnored var mergeWatch = MergeWatch()
    /// 読み込みを始めた数と、画面に当てた最後の読み込みの番号（後に始めた読み込みの結果を、先に始めた読み込みで上書きしない。
    /// 窓口も同じ決まりで送る形の引き当てを更新するので、読めなかった読み込みは番号を進めない）
    private var startedRefreshes = 0
    private var appliedRefresh = 0

    let service: any ClientService
    let undoDelay: Duration
    let noticeDuration: Duration
    /// 司令塔の受け取りを待ったまま、これより長くたったら、司令塔が動いていない可能性をその場に出す
    let stallThreshold: TimeInterval
    private let now: () -> Date
    private var pendingTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(
        service: any ClientService,
        undoDelay: Duration = .seconds(4),
        noticeDuration: Duration = .seconds(5),
        stallThreshold: TimeInterval = ClientStore.defaultStallThreshold,
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.undoDelay = undoDelay
        self.noticeDuration = noticeDuration
        self.stallThreshold = stallThreshold
        self.now = now
    }

    func currentDate() -> Date {
        now()
    }

    /// その意図を送れるか（送れない操作のボタンは画面に出さない）
    func supports(_ intent: HumanIntent) -> Bool {
        service.supports(intent)
    }

    /// 判断のカードのスクショの中身。読めなければ、そのわけ（画面に出す）
    func screenshot(at path: String) async -> Result<Data, ClientServiceError> {
        do {
            return .success(try await service.screenshot(at: path))
        } catch let error as ClientServiceError {
            return .failure(error)
        } catch {
            return .failure(ClientServiceError(message: error.localizedDescription))
        }
    }

    // MARK: 読む

    /// 読み直す。司令塔が受け付けた意図を見つけたら、状態が反映されるよう、続けてもう一度読む
    func refresh() async {
        if snapshot == nil {
            phase = .loading
        }
        startedRefreshes += 1
        let generation = startedRefreshes
        defer {
            lastRefreshEndedAt = .now
        }
        do {
            let fetched = try await service.fetchSnapshot()
            // 後に始めた読み込みが先に終わっていたら、古い中身で上書きしない
            guard generation > appliedRefresh else {
                return
            }
            appliedRefresh = generation
            snapshot = fetched
            // 送り終えていない意図は、読んだ状態にも当てたままにする
            if !optimisticIntents.isEmpty {
                rebuildSnapshot()
            }
            phase = .loaded
            refreshFailure = nil
            refreshPausedUntil = nil
            let receipts = reflections.receive(
                fetched,
                generation: generation,
                latestStarted: startedRefreshes,
                now: now(),
                trackingWindow: Self.receiptTrackingWindow
            )
            announceAccepted(receipts.acceptedAnnounced, in: fetched)
            if receipts.needsReread {
                await refresh()
            }
            watchAfterRefresh()
        } catch {
            // 後に始めた読み込みがもう読めていれば、古い失敗は出さない
            guard generation > appliedRefresh else {
                return
            }
            var message = error.localizedDescription
            // 上限に当たったら、言われた時刻まで取り直しも受け付けの確かめも休む（休まずに読むと、戻った直後の残りを食い潰す）
            if let wait = (error as? ClientServiceError)?.retryAfter {
                let until = now().addingTimeInterval(TimeInterval(wait.components.seconds))
                refreshPausedUntil = until
                receiptCheckPausedUntil = until
                message = Self.rateLimitMessage(until: until)
            }
            if snapshot == nil {
                phase = .failed(message)
            } else {
                refreshFailure = message
            }
        }
    }

    // MARK: 送る

    /// 取り消しの猶予つきで送る（スワイプ・選択肢）。猶予の間にほかを送ると、前のものはすぐ送る
    func enqueue(_ intent: HumanIntent, message: String) {
        if let current = pending {
            pendingTask?.cancel()
            pending = nil
            // 猶予の間の意図から送っている意図へ、間を空けずに移す（山札に戻って見えないように）
            let delivery = prepareDelivery(current.intent)
            Task { await complete(delivery, of: current.intent) }
        }
        let item = PendingIntent(intent: intent, message: message)
        pending = item
        rebuildSnapshot()
        pendingTask = Task { [undoDelay] in
            try? await Task.sleep(for: undoDelay)
            guard !Task.isCancelled else {
                return
            }
            await commitPending(item.id)
        }
    }

    /// 猶予の間に取り消す
    func undo() {
        pendingTask?.cancel()
        pendingTask = nil
        pending = nil
        rebuildSnapshot()
    }

    /// 猶予を待たずに送る（確認のダイアログやシートを経た操作。開始・依頼 など）。画面は押した時点で送った結果の形になり、
    /// 司令塔が受け付けたら帯で知らせる。失敗をシートの中で出すときは `reportsFailure` を false にして、帯には出さない
    @discardableResult
    func send(_ intent: HumanIntent, reportsFailure: Bool = true) async -> SendResult {
        await deliver(intent, announces: true, reportsFailure: reportsFailure)
    }

    /// シートから送り始めて、送り終えるのを待たずに戻る（シートはすぐ閉じ、画面は送った結果の形になる）。
    /// 送れなかったら帯で知らせて元に戻す。同じ対象への操作が同期を待っていて送らないときは、その理由を返す（帯には出さない）
    @discardableResult
    func submit(_ intent: HumanIntent) -> SubmitResult {
        let delivery = prepareDelivery(intent, announces: true, reportsFailure: true, reportsBusy: false)
        switch delivery {
        case .skipped(.failed(let message)):
            return .blocked(message)

        case .skipped:
            return .alreadySent

        case .started:
            Task { await complete(delivery, of: intent) }
            return .started
        }
    }

    /// 同じ内容の依頼を少し前に送っていれば、その時刻。送る前に、重ねて送るかを人に確かめる
    func recentlySentRequest(_ intent: HumanIntent) -> Date? {
        guard intent.isRequest, let record = service.lastSend(of: intent),
              now().timeIntervalSince(record.sentAt) < Self.duplicateRequestWindow else {
            return nil
        }
        return record.sentAt
    }

    func retryFailedSend() async {
        guard let failure = sendFailure else {
            return
        }
        await deliver(failure.intent, announces: true)
    }

    func dismissSendFailure() {
        sendFailure = nil
    }

    private func commitPending(_ id: UUID) async {
        guard let item = pending, item.id == id else {
            return
        }
        pending = nil
        pendingTask = nil
        await deliver(item.intent)
    }

    /// 送るかどうかを決めた結果
    private enum Delivery {
        /// 送らない（送ってある・送れない）
        case skipped(SendResult)
        /// 送り始めた（反映中として出している）
        case started(sendingID: UUID, announces: Bool, reportsFailure: Bool)
    }

    /// 送る。同じ意図を送っている途中か、送ってあって司令塔がまだ受け取っていなければ、送り直さない
    /// （依頼は、人が確かめたうえで同じ内容をもう一度送れる）。同じ対象へのほかの操作が反映されるまでは、送らない
    @discardableResult
    private func deliver(_ intent: HumanIntent, announces: Bool = false, reportsFailure: Bool = true) async -> SendResult {
        await complete(prepareDelivery(intent, announces: announces, reportsFailure: reportsFailure), of: intent)
    }

    /// 送るかを決め、送るなら同期待ちにして、送った結果として画面に当てる（待たずに決めるので、画面は押した直後から済んだ形になる）。
    /// 同じ対象への操作が同期を待っていて送らないときは、`reportsBusy` なら帯で知らせる
    private func prepareDelivery(
        _ intent: HumanIntent,
        announces: Bool = false,
        reportsFailure: Bool = true,
        reportsBusy: Bool = true
    ) -> Delivery {
        guard !unsent.contains(intent) else {
            return .skipped(.alreadySent)
        }
        if !intent.isRequest, service.lastSend(of: intent)?.isWaiting == true {
            clearFailure(of: intent)
            if announces {
                announce(SendNotice(message: "\(intent.label)は送ってあります"))
            }
            return .skipped(.alreadySent)
        }
        // 同じ操作の送り直し（途中で失敗したまとめて OK の残り）は、自分の送った分を理由に止めない
        let busy = reflections.reflection(matching: { intent.targets.contains($0) }, pending: pending?.intent, excluding: intent)
        if let busy, busy.isPending {
            let message = "\(busy.label)の同期を待っています。司令塔が受け付けてから操作してください"
            if reportsFailure, reportsBusy {
                sendFailure = SendFailure(intent: intent, message: message)
            }
            return .skipped(.failed(message))
        }
        unsent.append(intent)
        let sendingID = reflections.beginSending(intent)
        rebuildSnapshot()
        return .started(sendingID: sendingID, announces: announces, reportsFailure: reportsFailure)
    }

    private func complete(_ delivery: Delivery, of intent: HumanIntent) async -> SendResult {
        guard case let .started(sendingID, announces, reportsFailure) = delivery else {
            if case .skipped(let result) = delivery {
                return result
            }
            return .alreadySent
        }
        // 押した順に送る（司令塔は意図の番号の順に処理するので、判断に答えてから承認する、などの順を守る）
        let previous = sendTail
        let work = Task {
            await previous?.value
            return await perform(intent, sendingID: sendingID, announces: announces, reportsFailure: reportsFailure)
        }
        sendTail = Task { _ = await work.value }
        return await work.value
    }

    private func perform(_ intent: HumanIntent, sendingID: UUID, announces: Bool, reportsFailure: Bool) async -> SendResult {
        defer {
            if let index = unsent.firstIndex(of: intent) {
                unsent.remove(at: index)
            }
            // 送り終えた意図は窓口が当てたままにし、送れなかった意図は外す（画面を元に戻す）
            rebuildSnapshot()
        }
        do {
            let receipt = try await service.perform(intent)
            reflections.finishSending(sendingID, receipt: receipt, announces: announces, at: now())
            clearFailure(of: intent)
            watchReceipts()
            return .sent(receipt)
        } catch {
            // まとめて OK の途中で失敗したときは、書けた分を同期待ちとして追い続ける（もう一度送ると、残りだけを送る）
            let partial = (error as? ClientServiceError)?.sentBeforeFailure
            reflections.finishSending(sendingID, receipt: partial, announces: announces, at: now())
            let message = error.localizedDescription
            if reportsFailure {
                sendFailure = SendFailure(intent: intent, message: message)
            }
            if partial != nil {
                watchReceipts()
            }
            return .failed(message)
        }
    }

    /// 送った結果として画面に当てる意図（押した順）。依頼は、送り終えて epic の id が決まってから窓口が当てる
    private var optimisticIntents: [HumanIntent] {
        (unsent + [pending?.intent].compactMap(\.self)).filter { !$0.isRequest }
    }

    /// 最後に読んだ状態に、送り終えていない意図と、送り終えて読み直す前の意図を当て直す。当てられない窓口なら、読んだ状態のまま
    private func rebuildSnapshot() {
        guard snapshot != nil, let built = service.snapshot(overlaying: optimisticIntents) else {
            return
        }
        snapshot = built
    }

    /// 送れた意図の失敗の帯だけを消す（ほかの意図の失敗は、もう一度送れるように残す）
    private func clearFailure(of intent: HumanIntent) {
        if sendFailure?.intent == intent {
            sendFailure = nil
        }
    }
}

// MARK: - 帯の知らせ

extension ClientStore {
    /// 司令塔が受け付けた、帯で知らせて送った意図を知らせる（送れたことの帯を、その知らせに替える）。
    /// 断られたものは `rejections` に入り、閉じるまで帯とその場に出す
    private func announceAccepted(_ intents: [HumanIntent], in snapshot: ClientSnapshot) {
        guard let last = intents.last else {
            return
        }
        announce(Self.acceptedNotice(for: last, in: snapshot))
    }

    private static func acceptedNotice(for intent: HumanIntent, in snapshot: ClientSnapshot) -> SendNotice {
        switch intent {
        case let .start(_, macID):
            SendNotice(message: "\(snapshot.mac(macID)?.name ?? macID) で開始しました", detail: "作業場所の用意から進めます")

        default:
            SendNotice(message: "\(intent.label)を受け付けました", detail: "司令塔が受け取りました")
        }
    }

    private func announce(_ item: SendNotice) {
        notice = item
        noticeTask?.cancel()
        noticeTask = Task { [noticeDuration] in
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled, self.notice?.id == item.id else {
                return
            }
            self.notice = nil
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        notice = nil
    }

    /// 断られた知らせを閉じる（帯の次のものがあれば、それを出す）
    func dismissRejection() {
        guard let first = reflections.rejections.first else {
            return
        }
        reflections.dismissRejection(first.id)
    }

    /// 対象の場所に出した、断られた知らせを閉じる
    func dismissRejection(_ id: ReflectionTracker.Rejection.ID) {
        reflections.dismissRejection(id)
    }
}

// MARK: - 受け付けの確かめ

extension ClientStore {
    /// 司令塔の受け取りを待つ意図がある間だけ、受け付けの記録を数秒ごとに軽く確かめ、見つけたら全体を読み直す。
    /// 全体の取り直しの間隔は変えない。送ってから `stallThreshold` を過ぎた意図は確かめず、ふだんの取り直しに任せる
    func watchReceipts() {
        guard receiptWatch == nil, let interval = service.receiptCheckInterval, awaitedIntentID() != nil else {
            return
        }
        receiptWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, await self.checkReceipt() else {
                    break
                }
            }
            self?.receiptWatch = nil
        }
    }

    /// 受け付けを確かめる意図。司令塔は番号の順に処理するので、待っているうちで一番前に送ったものだけを確かめる（記録が無い間の読み取りも、上限に数えられる）
    private func awaitedIntentID() -> String? {
        reflections.oldestAwaitingIntentID(sentAfter: now().addingTimeInterval(-stallThreshold))
    }

    /// 1 回確かめる。確かめ続けるなら true
    private func checkReceipt() async -> Bool {
        guard let intentID = awaitedIntentID() else {
            return false
        }
        let date = now()
        if let until = receiptCheckPausedUntil, date < until {
            return true
        }
        do {
            if try await service.hasReceipt(for: intentID) {
                await refresh()
            }
        } catch {
            // 上限に当たったら、言われた間だけ休む。ほかの失敗は、次の間隔で確かめ直す
            if let wait = (error as? ClientServiceError)?.retryAfter {
                receiptCheckPausedUntil = date.addingTimeInterval(TimeInterval(wait.components.seconds))
            }
        }
        return true
    }
}
