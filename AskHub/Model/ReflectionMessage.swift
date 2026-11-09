import Foundation

/// 送った意図が反映されるまでの様子の文言。操作した場所に出す部品（`ReflectionStatusView`）とテストで使う
struct ReflectionMessage: Equatable {
    enum Tone: Equatable {
        /// 同期を待っている（送っている・司令塔の受け取りを待っている・受け付けて読み直している）
        case progress
        /// 司令塔がしばらく受け取っていない
        case stalled
        /// 司令塔が断った
        case rejected
    }

    /// 例: 同期待ち
    var title: String
    /// 例: マージの承認を司令塔が受け取るのを待っています
    var detail: String
    var tone: Tone
    /// 小さな印に出す短い言い方（例: 同期待ち）
    var badge: String
    /// 閉じられる知らせ（断られた）なら、その id
    var rejectionID: ReflectionTracker.Rejection.ID?

    /// 司令塔の生きている印がこれより古ければ、止まっているかもしれないと書く（印は 10 分ごとに書く。`ConnectionStatusView` と同じ）
    static let commanderSilence = ConnectionStatusView.staleHeartbeat

    /// 様子の文言。`stallThreshold` 秒より長く司令塔が受け取っていなければ、司令塔の生きている印（`commanderSeenAt`）と合わせて知らせる
    static func make(_ reflection: Reflection, now: Date, stallThreshold: TimeInterval, commanderSeenAt: Date?) -> ReflectionMessage {
        let label = reflection.label
        switch reflection.phase {
        case .sending:
            return ReflectionMessage(title: "同期待ち", detail: "\(label)を送っています", tone: .progress, badge: "同期待ち")

        case .waiting(let since) where reflection.isStalled(now: now, threshold: stallThreshold):
            let waited = RelativeTime.duration(since: since, now: now)
            return ReflectionMessage(
                title: "司令塔がまだ受け取っていません（\(waited)）",
                detail: stalledDetail(label: label, now: now, commanderSeenAt: commanderSeenAt),
                tone: .stalled,
                badge: "受け取り待ち"
            )

        case .waiting:
            return ReflectionMessage(
                title: "同期待ち",
                detail: "\(label)を司令塔が受け取るのを待っています（ふつうは 1 分ほど）",
                tone: .progress,
                badge: "同期待ち"
            )

        case .accepted:
            return ReflectionMessage(title: "同期待ち", detail: "\(label)を受け付けました。最新の状態を読んでいます", tone: .progress, badge: "同期待ち")

        case .rejected(let rejection):
            return ReflectionMessage(
                title: rejection.message,
                detail: rejection.reason,
                tone: .rejected,
                badge: "受け付けられず",
                rejectionID: rejection.id
            )
        }
    }

    /// 司令塔がしばらく受け取っていないときの見通し。生きている印が古ければ、司令塔が止まっているかもしれないと書く
    private static func stalledDetail(label: String, now: Date, commanderSeenAt: Date?) -> String {
        let resumes = "動き出せば、送った\(label)を受け取ります"
        guard let commanderSeenAt else {
            return "司令塔の生きている印を読めていません。司令塔の Mac が動いているか確かめてください。\(resumes)"
        }
        let silence = RelativeTime.duration(since: commanderSeenAt, now: now)
        if now.timeIntervalSince(commanderSeenAt) >= commanderSilence {
            return "司令塔から \(silence) 印がありません。司令塔の Mac が止まっているかもしれません。\(resumes)"
        }
        return "司令塔の最後の印は \(silence) 前です。混んでいるか、止まったばかりかもしれません。\(resumes)"
    }
}
