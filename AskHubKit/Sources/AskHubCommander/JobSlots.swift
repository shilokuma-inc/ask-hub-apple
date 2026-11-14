import AskHubJobs
import AskHubProtocol
import Foundation

/// 自分宛てのジョブを、Mac ごとの同時の上限の中で引き受けて並んで動かす（司令塔とワーカーで共通）。
///
/// ジョブの状態は司令塔が試行を読んで決めるので、引き受けてからしばらくはジョブが `assigned` のまま残る。
/// 動かしているのにまだ `running` になっていないジョブは引き受け直さず、そのぶん空きを減らす
public actor JobSlots {
    nonisolated public let mac: MacName
    nonisolated public let capacity: MacFile.Capacity
    /// この Mac が引き受けるジョブの種類。ほかの種類の `assigned` のジョブは、空きの計算に入れない
    nonisolated public let kinds: Set<JobKind>
    nonisolated let log: @Sendable (String) -> Void

    private var inFlight: [ULID: Task<Void, Never>] = [:]
    /// 前の起動で動いていた自分の試行を閉じ終えたか（起動して最初に引き受ける前に 1 度だけ行う）
    private var leftoversClosed = false

    public init(mac: MacName, capacity: MacFile.Capacity, kinds: Set<JobKind>, log: @escaping @Sendable (String) -> Void) {
        self.mac = mac
        self.capacity = capacity
        self.kinds = kinds
        self.log = log
    }

    /// 引き受けられるジョブを選んで動かし始める。動かし始めたジョブを返す
    @discardableResult
    public func fill(from jobs: [JobFile], now: Date, with worker: JobWorker) async -> [JobFile] {
        if !leftoversClosed {
            leftoversClosed = await closeLeftovers(of: jobs, with: worker.recorder)
        }
        let picked = pick(from: jobs, now: now)
        for job in picked {
            start(job, with: worker)
        }
        return picked
    }

    /// 動かしているジョブが終わるまで待つ
    public func waitForJobs() async {
        while let task = inFlight.values.first {
            await task.value
        }
    }

    /// 引き受けるジョブ。動かしているのにまだ試行が読まれていない（`assigned` のままの）ジョブは選ばず、そのぶん空きを減らす
    func pick(from jobs: [JobFile], now: Date) -> [JobFile] {
        let pending = jobs.filter { inFlight[$0.id] != nil && $0.state != .running }
        var capacity = capacity
        capacity.claude = max(0, capacity.claude - pending.filter(\.needs.claude).count)
        capacity.build = max(0, capacity.build - pending.filter(\.needs.build).count)
        // 引き受けない種類の assigned のジョブは、空きを取られないよう候補から外す（running・succeeded は空きと依存の判断に要るので残す）
        let candidates = jobs.filter { job in
            job.state != .assigned || (kinds.contains(job.kind) && inFlight[job.id] == nil)
        }
        return JobPicker.pick(from: candidates, for: mac, capacity: capacity, now: now)
    }

    /// 前の起動で動いていた自分の試行（実行中のまま残ったもの）を、Mac がオフラインで中断したものとして閉じる。閉じ終えたら true。
    ///
    /// 止める合図を扱わないので、ワーカーを止めた・Mac を再起動した・司令塔を入れ替えたときに、試行が実行中のまま残る。
    /// 残すと、司令塔は Mac の印が新しいのに試行の印が古いものとして時間切れに数え、後の試行の失敗の扱いでも時間切れとして数える
    /// （オフラインの間の中断は失敗に数えない。`docs/renewal/protocol.md` の「ジョブの引き受けと試行の段取り」）。
    /// 引き受けた後の試行の番号は、司令塔が読むまで `attempts` のままなので、`attempts + 1` 番も見る
    private func closeLeftovers(of jobs: [JobFile], with recorder: AttemptRecorder) async -> Bool {
        let mine = jobs.filter { $0.assignedMac == mac && [.assigned, .running, .paused].contains($0.state) && inFlight[$0.id] == nil }
        var closed = true
        for job in mine {
            for number in [job.attempts, job.attempts + 1] where number >= 1 {
                do {
                    guard let attempt = try await recorder.read(job, number: number), attempt.mac == mac, attempt.outcome == .running else {
                        continue
                    }
                    let failure = AttemptFailure(failureClass: .macOffline, message: "前の起動で動いていた試行を、ワーカーが止まったので中断した")
                    try await recorder.finish(attempt, of: job, failure: failure)
                    log("前の起動で動いていたジョブ \(job.kind.rawValue) \(job.id) の試行 #\(number) を、Mac がオフラインで中断したものとして閉じた")
                } catch {
                    closed = false
                    log("前の起動で動いていた試行を閉じられなかった（\(job.id) #\(number)、\(error)）。次の周でやり直す")
                }
            }
        }
        return closed
    }

    private func start(_ job: JobFile, with worker: JobWorker) {
        let log = log
        inFlight[job.id] = Task { [weak self] in
            do {
                if let attempt = try await worker.perform(job) {
                    log("ジョブ \(job.kind.rawValue) \(job.id) の試行 #\(attempt.number): \(attempt.outcome.rawValue)")
                }
            } catch {
                log("ジョブ \(job.kind.rawValue) \(job.id) を終えられなかった（\(error)）")
            }
            await self?.finished(job.id)
        }
    }

    private func finished(_ id: ULID) {
        inFlight[id] = nil
    }
}
