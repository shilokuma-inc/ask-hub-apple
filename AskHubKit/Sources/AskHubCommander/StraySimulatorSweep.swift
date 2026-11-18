import AskHubBuild
import Foundation

/// 動いているループに属さない枠の Simulator を、定期の見回りで消す（`docs/renewal/operations.md` の「容量」）。
///
/// 消すのは、ワーカーが作った枠の Simulator（`askhub-worker-<枠>-…`）のうち、枠の数を超えた番号のもの・ランタイムが無くなったもの・
/// 最後に使ってから `unusedFor` たったもの（`SimulatorPool.isStray`）。人が作った Simulator には触れない。
/// 枠の Simulator はジョブ（ビルド・テスト・撮影・片付け）がビルドの枠を借りて使うので、すべての枠を借りられたときだけ消し、
/// 使われていれば待たずに次の見回りに回す。消した Simulator は、次にその枠を使うジョブが同じ名前で作り直す
public struct StraySimulatorSweep: Sendable {
    /// 最後に使ってから消すまでの時間の既定。clone 本体を消す 7 日に合わせる（2026-11-18 に決めた）
    public static let defaultUnusedFor: TimeInterval = 7 * 24 * 60 * 60

    public var pool: SimulatorPool
    /// ジョブと同じビルドの枠（`MachineRuntime.buildSlots`）。枠の数が、残す枠の Simulator の番号の上限になる
    public var slots: BuildSlots
    public var unusedFor: TimeInterval
    public var now: @Sendable () -> Date
    public var log: @Sendable (String) -> Void

    public init(
        pool: SimulatorPool,
        slots: BuildSlots,
        unusedFor: TimeInterval = defaultUnusedFor,
        now: @escaping @Sendable () -> Date = Date.init,
        log: @escaping @Sendable (String) -> Void
    ) {
        self.pool = pool
        self.slots = slots
        self.unusedFor = unusedFor
        self.now = now
        self.log = log
    }

    /// 1 回見回る。枠を使っているジョブがあれば何もしない。消したものと消せなかったものをログに出す
    public func run() async {
        let (pool, count, unusedFor, now) = (pool, slots.count, unusedFor, now())
        let result: Result<StraySimulators, SimulatorError>? = await slots.withAllSlotsIfIdle {
            do throws(SimulatorError) {
                return .success(try await pool.removeStray(slots: count, now: now, unusedFor: unusedFor))
            } catch {
                return .failure(error)
            }
        }
        switch result {
        case nil:
            return
        case let .failure(error)?:
            log("使っていない枠の Simulator を探せなかった（\(error.message)）。次の見回りでやり直す")
        case let .success(sweep)?:
            if !sweep.removed.isEmpty {
                log("使っていない枠の Simulator を消した: \(sweep.removed.map(\.name).joined(separator: "・"))")
            }
            for failure in sweep.failures {
                log("使っていない枠の Simulator を消せなかった（\(failure.message)）。次の見回りでやり直す")
            }
        }
    }
}
