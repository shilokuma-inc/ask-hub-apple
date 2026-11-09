import Foundation
import Observation

/// 画面が読む状態と、人の意図を送る操作をまとめたもの。
///
/// 取得のライフサイクル（読み込み中・失敗・前回の値を残す）はここだけで持ち、画面ごとにコピーしない
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

    /// 送れたこと・司令塔が受け付けたことを知らせる帯（しばらくしたら消す）。司令塔が断ったことは `rejections` で閉じるまで出す
    struct SendNotice: Identifiable, Equatable {
        let id = UUID()
        /// 例: 依頼「週ごとのまとめ」を送りました
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

    private(set) var snapshot: ClientSnapshot?
    private(set) var phase: Phase = .idle
    /// 前回の取り直しの失敗。スナップショットは前のものを残し、失敗したことを帯で出す
    private(set) var refreshFailure: String?
    private(set) var pending: PendingIntent?
    private(set) var sendFailure: SendFailure?
    private(set) var notice: SendNotice?
    /// 送った意図が画面に反映されるまでの様子（対象ごと）と、司令塔が断った知らせ
    private(set) var reflections = ReflectionTracker()
    /// 送っている途中の意図。同じ意図は、送り終わるまで重ねて送らない
    private var sendingIntents: Set<HumanIntent> = []
    /// 読み込みを始めた数と、画面に当てた最後の読み込みの番号（後に始めた読み込みの結果を、先に始めた読み込みで上書きしない）
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

    // MARK: 読む

    /// 読み直す。司令塔が受け付けた意図を見つけたら、状態が反映されるよう、続けてもう一度読む
    func refresh() async {
        if snapshot == nil {
            phase = .loading
        }
        startedRefreshes += 1
        let generation = startedRefreshes
        do {
            let fetched = try await service.fetchSnapshot()
            // 後に始めた読み込みが先に終わっていたら、古い中身で上書きしない
            guard generation > appliedRefresh else {
                return
            }
            appliedRefresh = generation
            snapshot = fetched
            phase = .loaded
            refreshFailure = nil
            let receipts = reflections.receive(fetched, generation: generation, now: now(), trackingWindow: Self.receiptTrackingWindow)
            announceAccepted(receipts.acceptedAnnounced, in: fetched)
            if receipts.needsReread {
                await refresh()
            }
        } catch {
            guard generation > appliedRefresh else {
                return
            }
            appliedRefresh = generation
            let message = error.localizedDescription
            if snapshot == nil {
                phase = .failed(message)
            } else {
                refreshFailure = message
            }
        }
    }

    /// 画面を開いている間、決まった間隔で取り直す。呼び出し元の Task が取り消されると止まる
    func runAutoRefresh() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: service.refreshInterval)
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
    }

    /// 猶予を待たずに送り、送れたら帯で知らせる（確認のダイアログやシートを経た操作。開始・依頼 など）。
    /// 失敗をシートの中で出すときは `reportsFailure` を false にして、帯には出さない
    @discardableResult
    func send(_ intent: HumanIntent, reportsFailure: Bool = true) async -> SendResult {
        await deliver(intent, announces: true, reportsFailure: reportsFailure)
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

    /// 送るかを決め、送るなら反映中にする（待たずに決めるので、画面は押した直後から反映中になる）
    private func prepareDelivery(_ intent: HumanIntent, announces: Bool = false, reportsFailure: Bool = true) -> Delivery {
        guard !sendingIntents.contains(intent) else {
            return .skipped(.alreadySent)
        }
        if !intent.isRequest, service.lastSend(of: intent)?.isWaiting == true {
            clearFailure(of: intent)
            if announces {
                announce(SendNotice(message: "\(intent.label)は送ってあります"))
            }
            return .skipped(.alreadySent)
        }
        if let busy = reflection(for: intent.targets), busy.isPending {
            let message = "\(busy.label)を反映しています。反映されてから操作してください"
            if reportsFailure {
                sendFailure = SendFailure(intent: intent, message: message)
            }
            return .skipped(.failed(message))
        }
        sendingIntents.insert(intent)
        return .started(sendingID: reflections.beginSending(intent), announces: announces, reportsFailure: reportsFailure)
    }

    private func complete(_ delivery: Delivery, of intent: HumanIntent) async -> SendResult {
        guard case let .started(sendingID, announces, reportsFailure) = delivery else {
            if case .skipped(let result) = delivery {
                return result
            }
            return .alreadySent
        }
        defer { sendingIntents.remove(intent) }
        do {
            let receipt = try await service.perform(intent)
            reflections.finishSending(sendingID, receipt: receipt, announces: announces, at: now())
            clearFailure(of: intent)
            // 読み直しで司令塔が受け付けたと分かれば、送れたことの帯をその知らせに替える
            if announces {
                announce(SendNotice(message: "\(intent.label)を送りました"))
            }
            await refresh()
            return .sent(receipt)
        } catch {
            reflections.finishSending(sendingID, receipt: nil, announces: announces, at: now())
            let message = error.localizedDescription
            if reportsFailure {
                sendFailure = SendFailure(intent: intent, message: message)
            }
            return .failed(message)
        }
    }

    /// 送れた意図の失敗の帯だけを消す（ほかの意図の失敗は、もう一度送れるように残す）
    private func clearFailure(of intent: HumanIntent) {
        if sendFailure?.intent == intent {
            sendFailure = nil
        }
    }

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
}

extension ClientStore {
    var inboxItems: [InboxItem] {
        guard let snapshot else {
            return []
        }
        return InboxBuilder.items(from: snapshot, now: now())
    }

    var blockingCount: Int {
        inboxItems.filter { $0.urgency == .blocking }.count
    }

    func deckCards(_ scope: DeckScope) -> [DeckCard] {
        guard let snapshot else {
            return []
        }
        // 答えを送ったカードは、反映されるまで山札から外す（断られたら戻す）
        return DeckBuilder.cards(from: snapshot, scope: scope).filter { reflection(for: [$0.target])?.isPending != true }
    }

    func epic(_ id: Epic.ID) -> Epic? {
        snapshot?.epic(id)
    }

    func repository(_ id: TargetRepository.ID?) -> TargetRepository? {
        guard let id else {
            return nil
        }
        return snapshot?.repository(id)
    }

    func mac(_ id: Mac.ID?) -> Mac? {
        snapshot?.mac(id)
    }
}

// MARK: - 反映中

extension ClientStore {
    /// 対象の、送った意図が反映されるまでの様子。複数の対象なら、反映を待っているものを先に返す。何も無ければ nil
    func reflection(for targets: [IntentTarget]) -> Reflection? {
        let found = targets.compactMap { reflections.reflection(for: $0, pending: pending?.intent) }
        return found.first(where: \.isPending) ?? found.first
    }

    /// 意図の対象に、反映を待っている操作があるか（あれば、その操作のボタンを押せなくする）
    func isReflecting(_ intent: HumanIntent) -> Bool {
        isReflecting(intent.targets)
    }

    /// 対象に、反映を待っている操作があるか（あれば、その対象への操作を押せなくする）
    func isReflecting(_ targets: [IntentTarget]) -> Bool {
        reflection(for: targets)?.isPending == true
    }

    /// 司令塔が断った知らせ（古い順）。帯で 1 つずつ出し、対象の場所にも出す
    var rejections: [ReflectionTracker.Rejection] {
        reflections.rejections
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
