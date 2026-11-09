import Foundation

/// 送った意図が画面に反映されるまでの、ある対象の様子。操作した場所（カード・ボタン・行）に出す
struct Reflection: Equatable {
    enum Phase: Equatable {
        /// 送っている（GitHub に書いている）か、取り消しの猶予の間
        case sending
        /// 司令塔が受け取るのを待っている
        case waiting(since: Date)
        /// 司令塔が受け付けた。状態を読み直して画面に反映するのを待っている
        case accepted
        /// 司令塔が断った（閉じるか、同じ対象にもう一度送るまで残す）
        case rejected(ReflectionTracker.Rejection)
    }

    /// 何の操作か（例: マージの承認）
    var label: String
    var phase: Phase

    /// 反映を待っている間（同じ対象への操作を止める）
    var isPending: Bool {
        if case .rejected = phase {
            return false
        }
        return true
    }

    /// 司令塔の受け取りを待ったまま、`threshold` 秒より長くたったか
    func isStalled(now: Date, threshold: TimeInterval) -> Bool {
        guard case .waiting(let since) = phase else {
            return false
        }
        return now.timeIntervalSince(since) >= threshold
    }
}

/// 送った意図が画面に反映されるまでを、対象（`IntentTarget`）ごとに追う。
///
/// 送っている（GitHub に書いている）→ 司令塔の受け取り待ち（`consumed` が無い）→ 受け付けられて読み直し待ち → 反映（消す）の順に進む。
/// 受け付けた記録（`consumed`）は司令塔が状態を書き換えた後に書くが、並べて読む 1 回の読み込みでは書き換える前の状態を読むことがあるので、
/// 受け付けを見つけた後に始めた読み込みが終わるまで反映中とする。断られたら、理由を閉じるまで残す。
/// 前の起動で送って受け取り待ちの意図も、読んだ送った意図の一覧（`ClientSnapshot.sentIntents`）から反映中として出す
struct ReflectionTracker {
    /// 司令塔が断った知らせ
    struct Rejection: Identifiable, Equatable {
        let id = UUID()
        var targets: [IntentTarget]
        /// 例: マージの承認
        var label: String
        var reason: String

        var message: String { "\(label)を受け付けませんでした" }
        var detail: String { reason }
    }

    /// 読み込みで分かった、知らせること
    struct Receipts: Equatable {
        /// 司令塔が受け付けた、帯で知らせて送った意図（送った順）
        var acceptedAnnounced: [HumanIntent] = []
        /// 受け付けたものがあり、状態を読み直すと反映される
        var needsReread = false
    }

    /// 送っている途中の意図（送った意図の id がまだ分からない）
    private struct Sending {
        var intent: HumanIntent
    }

    /// この起動で送り、司令塔の受け取りを待っている意図
    private struct Awaiting {
        var intent: HumanIntent
        var targets: [IntentTarget]
        var sentAt: Date
        /// 送れたことを帯で知らせたか（受け付けたら、その帯を受け付けた知らせに替える）
        var announces: Bool
    }

    /// 受け付けられて、読み直しを待っている対象
    private struct Accepted {
        var targets: [IntentTarget]
        var label: String
        /// 受け付けを見つけた読み込みの番号。これより後に始めた読み込みが終わったら消す
        var observedIn: Int
    }

    private var sending: [UUID: Sending] = [:]
    /// 送った意図の id ごと
    private var awaiting: [String: Awaiting] = [:]
    /// 前に読んだときに受け取り待ちだった送った意図（前の起動で送ったものを含む）
    private var waitingInSnapshot: [String: SentIntentStatus] = [:]
    private var accepted: [Accepted] = []
    /// 断られた知らせ（古い順）
    private(set) var rejections: [Rejection] = []

    // MARK: 送る

    /// 送り始める。送り終えたら `finishSending` を呼ぶ
    mutating func beginSending(_ intent: HumanIntent) -> UUID {
        let id = UUID()
        sending[id] = Sending(intent: intent)
        // 同じ対象にもう一度送るので、前に断られた知らせは外す
        let targets = intent.targets
        rejections.removeAll { rejection in rejection.targets.contains(where: targets.contains) }
        return id
    }

    /// 送り終えた。書けなかったら（`receipt` が nil）、反映中を外す
    mutating func finishSending(_ id: UUID, receipt: SendReceipt?, announces: Bool, at date: Date) {
        guard let item = sending.removeValue(forKey: id), let receipt else {
            return
        }
        let targets = item.intent.targets + [receipt.requestedEpicID.map { IntentTarget.request(epicID: $0) }].compactMap(\.self)
        for intentID in receipt.intentIDs {
            awaiting[intentID] = Awaiting(intent: item.intent, targets: targets, sentAt: date, announces: announces)
        }
    }

    // MARK: 読む

    /// 読んだ送った意図の一覧から、司令塔が受け取ったものを見つける。
    /// `generation` は読み込みを始めた順の番号、`trackingWindow` は送った意図が一覧に見つからないときに待ち続ける間
    mutating func receive(_ snapshot: ClientSnapshot, generation: Int, now: Date, trackingWindow: TimeInterval) -> Receipts {
        // 受け付けを見つけた後に始めた読み込みなので、状態は反映されている
        accepted.removeAll { $0.observedIn < generation }
        let statuses = Dictionary(snapshot.sentIntents.map { ($0.id, $0) }) { first, _ in first }
        var receipts = Receipts()
        let ownIDs = Set(awaiting.keys)
        // この起動で送った意図（送った順）
        for (intentID, item) in awaiting.sorted(by: { ($0.value.sentAt, $0.key) < ($1.value.sentAt, $1.key) }) {
            let status = statuses[intentID]
            switch status?.state {
            case .waiting:
                continue

            case .accepted:
                accepted.append(Accepted(targets: item.targets, label: item.intent.label, observedIn: generation))
                receipts.needsReread = true
                if item.announces {
                    receipts.acceptedAnnounced.append(item.intent)
                }

            case .rejected(_, let reason):
                rejections.append(Rejection(targets: item.targets, label: item.intent.label, reason: reason))

            case nil:
                // 読んだ中に無いのは、その意図だけ読めなかったときもあるので、しばらくは待ち続ける
                // （送った意図を出さない窓口や、新しい 20 件から外れた意図は、待つ間を過ぎたら忘れる）
                guard now.timeIntervalSince(item.sentAt) >= trackingWindow else {
                    continue
                }
            }
            awaiting[intentID] = nil
        }
        // 前の起動で送り、前に読んだときに受け取り待ちだった意図
        for (intentID, previous) in waitingInSnapshot.sorted(by: { ($0.value.sentAt, $0.key) < ($1.value.sentAt, $1.key) })
        where !ownIDs.contains(intentID) {
            let targets = [previous.target].compactMap(\.self)
            switch statuses[intentID]?.state {
            case .accepted:
                accepted.append(Accepted(targets: targets, label: previous.title, observedIn: generation))
                receipts.needsReread = true

            case .rejected(_, let reason):
                rejections.append(Rejection(targets: targets, label: previous.title, reason: reason))

            case .waiting, nil:
                break
            }
        }
        waitingInSnapshot = statuses.filter { $0.value.state == .waiting }
        return receipts
    }

    // MARK: 対象ごとの様子

    /// 対象の様子。送っている・受け取り待ち・読み直し待ちを、断られた知らせより先に返す。何も無ければ nil
    func reflection(for target: IntentTarget, pending: HumanIntent?) -> Reflection? {
        if let item = sending.values.first(where: { $0.intent.targets.contains(target) }) {
            return Reflection(label: item.intent.label, phase: .sending)
        }
        if let pending, pending.targets.contains(target) {
            return Reflection(label: pending.label, phase: .sending)
        }
        var waiting: [(label: String, since: Date)] = awaiting.values.filter { $0.targets.contains(target) }.map { ($0.intent.label, $0.sentAt) }
        waiting += waitingInSnapshot.values.filter { status in status.target == target && !awaiting.keys.contains(status.id) }
            .map { ($0.title, $0.sentAt) }
        // 一番前に送ったものの時刻で、司令塔が受け取らないまま時間がたったかを決める
        if let oldest = waiting.min(by: { $0.since < $1.since }) {
            return Reflection(label: oldest.label, phase: .waiting(since: oldest.since))
        }
        if let item = accepted.last(where: { $0.targets.contains(target) }) {
            return Reflection(label: item.label, phase: .accepted)
        }
        if let rejection = rejections.last(where: { $0.targets.contains(target) }) {
            return Reflection(label: rejection.label, phase: .rejected(rejection))
        }
        return nil
    }

    // MARK: 断られた知らせ

    /// 断られた知らせを閉じる
    mutating func dismissRejection(_ id: Rejection.ID) {
        rejections.removeAll { $0.id == id }
    }
}
