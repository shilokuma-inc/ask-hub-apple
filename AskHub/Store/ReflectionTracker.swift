import Foundation

/// 送った意図が画面に反映されるまでの、ある対象の様子。
///
/// 画面は押した時点で送った結果の形になるので、同期を待つ間は行やカードの隅に小さな印だけを出し、
/// 司令塔が断った・しばらく受け取っていないときだけ、操作した場所に理由を出す
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

    /// 操作した場所に知らせることがあるか（司令塔が断った・しばらく受け取っていない）。同期を待っているだけなら false
    func needsAttention(now: Date, threshold: TimeInterval) -> Bool {
        if case .rejected = phase {
            return true
        }
        return isStalled(now: now, threshold: threshold)
    }
}

/// 送った意図が画面に反映されるまでを、対象（`IntentTarget`）ごとに追う。
///
/// 送っている（GitHub に書いている）→ 司令塔の受け取り待ち（`consumed` が無い）→ 受け付けられて読み直し待ち → 反映（消す）の順に進む。
/// 受け付けた記録（`consumed`）は司令塔が状態を書き換えた後に書くが、並べて読む 1 回の読み込みでは書き換える前の状態を読むことがあるので、
/// 受け付けを見つけた後に始めた読み込みが終わるまで反映中とする。断られたら、理由を閉じるまで残す。
/// まとめて OK のように 1 つの操作が複数の意図になるときは、意図ごとに、その意図で答えた対象だけを追う。
/// 前の起動で送って受け取り待ちの意図も、読んだ送った意図の一覧（`ClientSnapshot.sentIntents`）から反映中として出す
struct ReflectionTracker {
    /// 司令塔が断った知らせ
    struct Rejection: Identifiable, Equatable {
        let id = UUID()
        var targets: [IntentTarget]
        /// 例: マージの承認
        var label: String
        var reason: String
        /// この起動で送った操作（まとめて OK のように複数の意図になった操作の知らせを 1 つにまとめる）。前の起動で送ったものは nil
        var intent: HumanIntent?

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
        /// 受け付けを見つけたときに始めてあった読み込みの最後の番号。これより後に始めた読み込みが終わったら消す
        var observedAfter: Int
    }

    /// 前に読んだときに受け取り待ちだった送った意図
    private struct PreviousWaiting {
        var status: SentIntentStatus
        /// 読んだ中に見つからなくなった時刻（その意図だけ読めなかったときも、しばらくは待ち続ける）。見つかっている間は nil
        var missingSince: Date?
    }

    private var sending: [UUID: Sending] = [:]
    /// 送った意図の id ごと
    private var awaiting: [String: Awaiting] = [:]
    /// 前に読んだときに受け取り待ちだった送った意図（前の起動で送ったものを含む）
    private var waitingInSnapshot: [String: PreviousWaiting] = [:]
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

    /// 送り終えた。書けなかったら（`receipt` が nil）、反映中を外す。途中まで書けたときは、書けた意図だけを追う
    mutating func finishSending(_ id: UUID, receipt: SendReceipt?, announces: Bool, at date: Date) {
        guard let item = sending.removeValue(forKey: id), let receipt else {
            return
        }
        // 意図ごとの対象が分からなければ、操作の対象すべてとみなす
        let operationTargets = item.intent.targets + [receipt.requestedEpicID.map { IntentTarget.request(epicID: $0) }].compactMap(\.self)
        for sent in receipt.sent {
            let targets = sent.target.map { [$0] } ?? operationTargets
            awaiting[sent.id] = Awaiting(intent: item.intent, targets: targets, sentAt: date, announces: announces)
        }
    }

    // MARK: 読む

    /// 読んだ送った意図の一覧から、司令塔が受け取ったものを見つける。
    /// `generation` は終わった読み込みを始めた順の番号、`latestStarted` はいま始めてある読み込みの最後の番号、
    /// `trackingWindow` は送った意図が一覧に見つからないときに待ち続ける間
    mutating func receive(
        _ snapshot: ClientSnapshot,
        generation: Int,
        latestStarted: Int,
        now: Date,
        trackingWindow: TimeInterval
    ) -> Receipts {
        // 受け付けを見つけた後に始めた読み込みなので、状態は反映されている
        accepted.removeAll { generation > $0.observedAfter }
        let statuses = Dictionary(snapshot.sentIntents.map { ($0.id, $0) }) { first, _ in first }
        var receipts = Receipts()
        let ownIDs = Set(awaiting.keys)
        receiveOwn(statuses, observedAfter: latestStarted, now: now, trackingWindow: trackingWindow, into: &receipts)
        receivePrevious(statuses, excluding: ownIDs, observedAfter: latestStarted, into: &receipts)
        rememberWaiting(statuses, now: now, trackingWindow: trackingWindow)
        return receipts
    }

    /// 受け取り待ちの送った意図を覚える。前に受け取り待ちだった意図が読んだ中に無いときは、その意図だけ読めなかったこともあるので、しばらくは覚えておく
    private mutating func rememberWaiting(_ statuses: [String: SentIntentStatus], now: Date, trackingWindow: TimeInterval) {
        var waiting = statuses.filter { $0.value.state == .waiting }.mapValues { PreviousWaiting(status: $0, missingSince: nil) }
        for (intentID, previous) in waitingInSnapshot where statuses[intentID] == nil && awaiting[intentID] == nil {
            let missingSince = previous.missingSince ?? now
            if now.timeIntervalSince(missingSince) < trackingWindow {
                waiting[intentID] = PreviousWaiting(status: previous.status, missingSince: missingSince)
            }
        }
        waitingInSnapshot = waiting
    }

    /// この起動で送った意図（送った順）のうち、司令塔が受け取ったもの
    private mutating func receiveOwn(
        _ statuses: [String: SentIntentStatus],
        observedAfter: Int,
        now: Date,
        trackingWindow: TimeInterval,
        into receipts: inout Receipts
    ) {
        for (intentID, item) in awaiting.sorted(by: { ($0.value.sentAt, $0.key) < ($1.value.sentAt, $1.key) }) {
            switch statuses[intentID]?.state {
            case .waiting:
                continue

            case .accepted:
                accepted.append(Accepted(targets: item.targets, label: item.intent.label, observedAfter: observedAfter))
                receipts.needsReread = true
                if item.announces {
                    receipts.acceptedAnnounced.append(item.intent)
                }

            case .rejected(_, let reason):
                addRejection(Rejection(targets: item.targets, label: item.intent.label, reason: reason, intent: item.intent))

            case nil:
                // 読んだ中に無いのは、その意図だけ読めなかったときもあるので、しばらくは待ち続ける
                // （送った意図を出さない窓口や、新しい 20 件から外れた意図は、待つ間を過ぎたら忘れる）
                guard now.timeIntervalSince(item.sentAt) >= trackingWindow else {
                    continue
                }
            }
            awaiting[intentID] = nil
        }
    }

    /// 前の起動で送り、前に読んだときに受け取り待ちだった意図のうち、司令塔が受け取ったもの
    private mutating func receivePrevious(
        _ statuses: [String: SentIntentStatus],
        excluding ownIDs: Set<String>,
        observedAfter: Int,
        into receipts: inout Receipts
    ) {
        let previous = waitingInSnapshot.values.map(\.status).filter { !ownIDs.contains($0.id) }
        for status in previous.sorted(by: { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) }) {
            let targets = [status.target].compactMap(\.self)
            switch statuses[status.id]?.state {
            case .accepted:
                accepted.append(Accepted(targets: targets, label: status.title, observedAfter: observedAfter))
                receipts.needsReread = true

            case .rejected(_, let reason):
                rejections.append(Rejection(targets: targets, label: status.title, reason: reason))

            case .waiting, nil:
                break
            }
        }
    }

    /// 司令塔の受け取りを待っている意図のうち、`cutoff` より後に送った一番前のものの id（受け付けの記録を軽く確かめるのに使う）
    func oldestAwaitingIntentID(sentAfter cutoff: Date) -> String? {
        let own = awaiting.map { (id: $0.key, sentAt: $0.value.sentAt) }
        let previous = waitingInSnapshot.values.map { (id: $0.status.id, sentAt: $0.status.sentAt) }
        return (own + previous).filter { $0.sentAt > cutoff }.min { ($0.sentAt, $0.id) < ($1.sentAt, $1.id) }?.id
    }

    // MARK: 対象ごとの様子

    /// 条件に合う対象の様子。送っている・受け取り待ち・読み直し待ちを、断られた知らせより先に返す。何も無ければ nil。
    /// `excluding` の操作が送った分（送り直すときの自分の分）は数えない
    func reflection(matching isTarget: (IntentTarget) -> Bool, pending: HumanIntent?, excluding: HumanIntent? = nil) -> Reflection? {
        if let item = sending.values.first(where: { $0.intent != excluding && $0.intent.targets.contains(where: isTarget) }) {
            return Reflection(label: item.intent.label, phase: .sending)
        }
        if let pending, pending != excluding, pending.targets.contains(where: isTarget) {
            return Reflection(label: pending.label, phase: .sending)
        }
        var waiting = awaiting.values.filter { $0.intent != excluding && $0.targets.contains(where: isTarget) }
            .map { (label: $0.intent.label, since: $0.sentAt) }
        let previous = waitingInSnapshot.values.map(\.status).filter { status in
            status.target.map(isTarget) == true && awaiting[status.id] == nil
        }
        waiting += previous.map { (label: $0.title, since: $0.sentAt) }
        // 一番前に送ったものの時刻で、司令塔が受け取らないまま時間がたったかを決める
        if let oldest = waiting.min(by: { $0.since < $1.since }) {
            return Reflection(label: oldest.label, phase: .waiting(since: oldest.since))
        }
        if let item = accepted.last(where: { $0.targets.contains(where: isTarget) }) {
            return Reflection(label: item.label, phase: .accepted)
        }
        if let rejection = rejections.last(where: { $0.targets.contains(where: isTarget) }) {
            return Reflection(label: rejection.label, phase: .rejected(rejection))
        }
        return nil
    }

    // MARK: 断られた知らせ

    /// 断られた知らせを足す。1 つの操作から出た意図が同じ理由で断られたら（まとめて OK のカードごとの答え）、知らせを 1 つにまとめる
    private mutating func addRejection(_ rejection: Rejection) {
        guard rejection.intent != nil,
              let index = rejections.firstIndex(where: { $0.intent == rejection.intent && $0.reason == rejection.reason }) else {
            rejections.append(rejection)
            return
        }
        rejections[index].targets += rejection.targets.filter { !rejections[index].targets.contains($0) }
    }

    /// 断られた知らせを閉じる
    mutating func dismissRejection(_ id: Rejection.ID) {
        rejections.removeAll { $0.id == id }
    }
}
