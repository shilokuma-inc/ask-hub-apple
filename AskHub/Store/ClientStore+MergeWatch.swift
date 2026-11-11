import Foundation

// MARK: - マージの見届け

/// マージ中の epic を、マージ済みになるまで短い間隔で読み直すための様子。
/// 司令塔はマージし終えた次の周で epic をマージ済みにするので、30 秒ごとの取り直しを待つと、マージ済みの表示が遅れる
struct MergeWatch {
    /// epic ごとの、マージ中と最初に読んだ時刻
    private(set) var mergingSince: [Epic.ID: Date] = [:]
    /// 短い間隔で読み直している間の Task。読み直す epic が無くなったら終わる
    var task: Task<Void, Never>?

    /// 読んだ状態のマージ中の epic を覚え直す。マージ中になってから `window` 秒より短い epic があれば true
    mutating func update(with snapshot: ClientSnapshot?, now: Date, window: TimeInterval) -> Bool {
        let merging = Set(snapshot?.epics.filter { $0.finalReview?.state == .merging }.map(\.id) ?? [])
        mergingSince = mergingSince.filter { merging.contains($0.key) }
        for id in merging where mergingSince[id] == nil {
            mergingSince[id] = now
        }
        return mergingSince.values.contains { now.timeIntervalSince($0) < window }
    }
}

extension ClientStore {
    /// マージ中の epic を短い間隔で読み直し続ける長さ。これより長くマージ中のままなら、ふだんの取り直しに任せる
    static let mergeWatchWindow: TimeInterval = 10 * 60

    /// 読めた後に、受け付けの記録の確かめと、マージ中の epic の読み直しを始める（どちらも要るときだけ）
    func watchAfterRefresh() {
        watchReceipts()
        watchMerges()
    }

    /// マージ中の epic がある間だけ、窓口の `mergeWatchInterval` ごとに読み直す（ふだんの取り直しの間隔は変えない）。
    /// GitHub の上限に当たって取り直しを休んでいる間は読まない
    func watchMerges() {
        guard mergeWatch.task == nil, let interval = service.mergeWatchInterval, needsMergeWatch() else {
            return
        }
        mergeWatch.task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self, self.needsMergeWatch() else {
                    break
                }
                if !self.isRefreshPaused {
                    await self.refresh()
                }
            }
            self?.mergeWatch.task = nil
        }
    }

    private func needsMergeWatch() -> Bool {
        mergeWatch.update(with: snapshot, now: currentDate(), window: Self.mergeWatchWindow)
    }
}
