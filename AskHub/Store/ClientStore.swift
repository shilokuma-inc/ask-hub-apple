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

    /// 取り消しの猶予の間、送らずに持っている意図
    struct PendingIntent: Identifiable, Equatable {
        let id = UUID()
        let intent: HumanIntent
        /// 例: 献立メモ · 質問 Q3: 月曜の朝 9 時に固定
        let message: String
        /// 送った扱いにして一覧から隠す項目（判断のカードの id など）
        let itemID: String?
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

    /// 送れたこと・司令塔が受け付けたこと（しばらくしたら消す）と、司令塔が断ったこと（閉じるまで残す）を知らせる帯
    struct SendNotice: Identifiable, Equatable {
        let id = UUID()
        /// 例: 依頼「週ごとのまとめ」を送りました
        let message: String
        /// 送った後の見通し（状態リポジトリの「送った意図」・epic の履歴と同じ言い方にする）。断られたときは理由
        var detail = "司令塔が受け取るのを待っています"
    }

    /// 司令塔が受け取るのを待っている、帯で知らせて送った意図
    private struct AwaitingReceipt {
        let intent: HumanIntent
        let sentAt: Date
    }

    /// 同じ内容の依頼を重ねて送る前に、確かめる間
    static let duplicateRequestWindow: TimeInterval = 60
    /// 送った意図が読んだ中に見つからない（読めなかった・新しい 20 件から外れた）とき、受け付けを待ち続ける間
    static let receiptTrackingWindow: TimeInterval = 10 * 60

    private(set) var snapshot: ClientSnapshot?
    private(set) var phase: Phase = .idle
    /// 前回の取り直しの失敗。スナップショットは前のものを残し、失敗したことを帯で出す
    private(set) var refreshFailure: String?
    private(set) var pending: PendingIntent?
    private(set) var sendFailure: SendFailure?
    private(set) var notice: SendNotice?
    /// 司令塔が断った意図の知らせ（古い順）。ほかの帯に上書きされないよう分けて持ち、閉じるまで 1 つずつ出す
    private(set) var rejections: [SendNotice] = []
    /// 送ったが、まだ取り直しに反映されていない項目
    private(set) var hiddenItemIDs: Set<String> = []
    /// 送っている途中の意図。同じ意図は、送り終わるまで重ねて送らない
    private var sendingIntents: Set<HumanIntent> = []
    /// 帯で知らせて送った意図のうち、司令塔が受け取るのを待っているもの（送った意図の id ごと）
    private var awaitingReceipts: [String: AwaitingReceipt] = [:]

    let service: any ClientService
    let undoDelay: Duration
    let noticeDuration: Duration
    private let now: () -> Date
    private var pendingTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(
        service: any ClientService,
        undoDelay: Duration = .seconds(4),
        noticeDuration: Duration = .seconds(5),
        now: @escaping () -> Date = Date.init
    ) {
        self.service = service
        self.undoDelay = undoDelay
        self.noticeDuration = noticeDuration
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

    func refresh() async {
        if snapshot == nil {
            phase = .loading
        }
        do {
            let fetched = try await service.fetchSnapshot()
            snapshot = fetched
            phase = .loaded
            refreshFailure = nil
            // 送った項目は取り直しに反映されたので、猶予の間のものだけを隠し続ける
            hiddenItemIDs = Set([pending?.itemID].compactMap(\.self))
            announceReceipts(in: fetched)
        } catch {
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
    func enqueue(_ intent: HumanIntent, message: String, itemID: String? = nil) {
        if let current = pending {
            pendingTask?.cancel()
            Task { await deliver(current.intent) }
        }
        let item = PendingIntent(intent: intent, message: message, itemID: itemID)
        pending = item
        if let itemID {
            hiddenItemIDs.insert(itemID)
        }
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
        if let itemID = pending?.itemID {
            hiddenItemIDs.remove(itemID)
        }
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

    /// 送る。同じ意図を送っている途中か、送ってあって司令塔がまだ受け取っていなければ、送り直さない
    /// （依頼は、人が確かめたうえで同じ内容をもう一度送れる）
    @discardableResult
    private func deliver(_ intent: HumanIntent, announces: Bool = false, reportsFailure: Bool = true) async -> SendResult {
        guard !sendingIntents.contains(intent) else {
            return .alreadySent
        }
        if !intent.isRequest, service.lastSend(of: intent)?.isWaiting == true {
            clearFailure(of: intent)
            if announces {
                announce(SendNotice(message: "\(intent.label)は送ってあります"))
            }
            return .alreadySent
        }
        sendingIntents.insert(intent)
        defer { sendingIntents.remove(intent) }
        do {
            let receipt = try await service.perform(intent)
            clearFailure(of: intent)
            // 読み直しで司令塔が受け付けたと分かれば、送れたことの帯をその知らせに替える
            if announces {
                announce(SendNotice(message: "\(intent.label)を送りました"))
                if let intentID = receipt.intentID {
                    awaitingReceipts[intentID] = AwaitingReceipt(intent: intent, sentAt: now())
                }
            }
            await refresh()
            return .sent(receipt)
        } catch {
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

    /// 司令塔が受け取った意図を帯で知らせる。受け付けたものは送れたことの帯に替え、断られたものは理由を閉じるまで出す
    private func announceReceipts(in snapshot: ClientSnapshot) {
        var accepted: SendNotice?
        for (intentID, awaiting) in awaitingReceipts.sorted(by: { ($0.value.sentAt, $0.key) < ($1.value.sentAt, $1.key) }) {
            switch snapshot.sentIntents.first(where: { $0.id == intentID })?.state {
            case .waiting:
                continue

            case .accepted:
                accepted = Self.acceptedNotice(for: awaiting.intent, in: snapshot)

            case .rejected(_, let reason):
                rejections.append(SendNotice(message: "\(awaiting.intent.label)を受け付けませんでした", detail: reason))

            case nil:
                // 読んだ中に無いのは、その意図だけ読めなかったときもあるので、しばらくは待ち続ける
                // （送った意図を出さない窓口や、新しい 20 件から外れた意図は、待つ間を過ぎたら忘れる）
                guard now().timeIntervalSince(awaiting.sentAt) >= Self.receiptTrackingWindow else {
                    continue
                }
            }
            awaitingReceipts[intentID] = nil
        }
        if let accepted {
            announce(accepted)
        }
    }

    /// 断られた知らせを閉じる（次のものがあれば、それを出す）
    func dismissRejection() {
        guard !rejections.isEmpty else {
            return
        }
        rejections.removeFirst()
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
        return DeckBuilder.cards(from: snapshot, scope: scope).filter { !hiddenItemIDs.contains($0.id) }
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
