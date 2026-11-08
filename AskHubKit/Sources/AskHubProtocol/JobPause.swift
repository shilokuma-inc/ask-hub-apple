import Foundation

extension JobFile {
    /// Mac がオフラインで止まった（`paused` の）ジョブか。当てた試行（番号が `attempts` のもの）が、担当の Mac で実行中のまま止まったか、
    /// Mac がオフラインとして失敗したもの。同じ Mac が戻れば、司令塔が続きから動かす。
    ///
    /// `paused` でもこれに当たらないジョブは、人の一時停止（`EpicFile.pause`）で止めたもの（再開で `assigned` に戻す）。
    /// ほかの Mac に引き継いで担当の Mac が変わったジョブも、前の Mac の試行を待たないので、これに当たらない
    public func isWaitingForOfflineMac(_ attempts: [AttemptFile]) -> Bool {
        guard state == .paused, let applied = attempts.first(where: { $0.job == id && $0.number == self.attempts }),
              applied.mac == assignedMac else {
            return false
        }
        return applied.outcome == .running || applied.failure?.failureClass == .macOffline
    }
}
