import AskHubProtocol
import Foundation

/// 人の一時停止（`EpicFile.pause`）と、ほかの Mac への引き継ぎ（`EpicFile.mac` の書き換え）の後の、ジョブの扱い
/// （`docs/renewal/operations.md` の「Mac の一時停止・再開・引き継ぎ」）。司令塔が、試行を当てた後のジョブに epic ごとに当てる。
///
/// - 一時停止の間は、引き受けられる（`queued`・`assigned`）ジョブを `paused` にしたままにする。動いているジョブは最後まで終わらせる
/// - 一時停止で止めたジョブと、Mac がオフラインで止まったジョブ（`JobFile.isWaitingForOfflineMac`）を分ける。
///   再開したら前者だけを `assigned` に戻し、後者は同じ Mac が戻るのを待つ
/// - 引き継いだら、epic の Mac で動くジョブのうち動いていないものを、epic の今の Mac に付け替える
public enum EpicHold {
    /// epic の Mac で動くジョブの種類（epic の作業場所を使う。`TaskFlow` と `FinalJobs` が epic の Mac に割り当てるもの）
    public static let epicMacKinds: Set<JobKind> = [
        .prepareWorkspace, .implementTask, .reviewTask, .fixTask, .integrateDevelop, .verifyBeforeFinal, .captureScreenshots, .cleanUp
    ]

    /// 付け替える（動いていない・終わっていない）ジョブの状態
    static let movableStates: Set<JobState> = [.queued, .assigned, .paused, .waitingHuman]

    /// 一時停止している epic のジョブ（`next` は試行を当てた後、`job` は当てる前）を止めたままにする。
    ///
    /// 一時停止で止めたジョブは、新しい試行が来るか成功するまで、前の試行の失敗で決め直さない（人の「やり直す」で戻したジョブを、人の対応待ちに戻さない）。
    /// 止めたままのジョブは、待ちの時刻だけが動いても書き直さない（周ごとに書かない）
    public static func hold(_ next: JobFile, was job: JobFile, attempts: [AttemptFile], now: Date) -> JobFile {
        var held = next
        if job.state == .paused, !job.isWaitingForOfflineMac(attempts), next.state != .succeeded, next.attempts == job.attempts {
            held.state = job.state
            held.nextRunAt = job.nextRunAt
        } else if [.queued, .assigned].contains(next.state) {
            held.state = .paused
            if job.state == .paused, next.attempts == job.attempts { held.nextRunAt = job.nextRunAt }
        }
        return settled(held, was: job, now: now)
    }

    /// 一時停止していない epic のジョブを動かせるようにする。一時停止で止めたジョブ（オフラインの Mac を待っていない `paused`）は、
    /// 再開で印を外した後に、前の試行の失敗で決め直さずに `assigned` に戻す（待ちの時刻は止めたときのまま）
    public static func release(_ next: JobFile, was job: JobFile, attempts: [AttemptFile], now: Date) -> JobFile {
        guard job.state == .paused, !job.isWaitingForOfflineMac(attempts), next.state != .succeeded, next.attempts == job.attempts else {
            return next
        }
        var released = next
        released.state = .assigned
        released.nextRunAt = job.nextRunAt
        return settled(released, was: job, now: now)
    }

    /// 引き継いだ epic のジョブを、epic の今の Mac（`epicMac`）に付け替える。動いている・終わったジョブは触らない。
    /// 前の Mac がオフラインで止まったままのジョブは、前の Mac を待たずに `assigned` に戻す（一時停止の間は `hold` が止めたままにする）。
    /// 最終 PR の直しは、epic の Mac がオフラインなら司令塔の Mac（`commander`）で動くので、司令塔の Mac のものは触らない
    public static func realign(_ next: JobFile, to epicMac: MacName, commander: MacName, attempts: [AttemptFile], now: Date) -> JobFile {
        guard movableStates.contains(next.state), let current = next.assignedMac, current != epicMac else { return next }
        guard epicMacKinds.contains(next.kind) || (next.kind == .fixFinalPullRequest && current != commander) else { return next }
        var moved = next
        moved.assignedMac = epicMac
        if next.isWaitingForOfflineMac(attempts) {
            moved.state = .assigned
            moved.nextRunAt = nil
        }
        return settled(moved, was: next, now: now)
    }

    /// 前と変わっていなければ前のもの（更新の時刻も動かさない）、変わっていれば更新の時刻を `now` にしたもの
    private static func settled(_ next: JobFile, was job: JobFile, now: Date) -> JobFile {
        var probe = next
        probe.updatedAt = job.updatedAt
        guard probe != job else { return job }
        var changed = next
        changed.updatedAt = Timestamp(now)
        return changed
    }
}
