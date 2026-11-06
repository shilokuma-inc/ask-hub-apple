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

    private(set) var snapshot: ClientSnapshot?
    private(set) var phase: Phase = .idle
    /// 前回の取り直しの失敗。スナップショットは前のものを残し、失敗したことを帯で出す
    private(set) var refreshFailure: String?
    private(set) var pending: PendingIntent?
    private(set) var sendFailure: SendFailure?
    private(set) var isSending = false
    /// 送ったが、まだ取り直しに反映されていない項目
    private(set) var hiddenItemIDs: Set<String> = []

    let service: any ClientService
    let undoDelay: Duration
    private let now: () -> Date
    private var pendingTask: Task<Void, Never>?

    init(service: any ClientService, undoDelay: Duration = .seconds(4), now: @escaping () -> Date = Date.init) {
        self.service = service
        self.undoDelay = undoDelay
        self.now = now
    }

    func currentDate() -> Date {
        now()
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

    /// 猶予を待たずに送る（確認のダイアログを経た操作。開始・マージ など）
    @discardableResult
    func send(_ intent: HumanIntent) async -> Bool {
        await deliver(intent)
    }

    func retryFailedSend() async {
        guard let failure = sendFailure else {
            return
        }
        await deliver(failure.intent)
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

    @discardableResult
    private func deliver(_ intent: HumanIntent) async -> Bool {
        isSending = true
        defer { isSending = false }
        do {
            try await service.perform(intent)
            sendFailure = nil
            await refresh()
            return true
        } catch {
            sendFailure = SendFailure(intent: intent, message: error.localizedDescription)
            return false
        }
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
