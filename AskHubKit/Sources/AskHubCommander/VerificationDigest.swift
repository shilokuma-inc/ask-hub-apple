import AskHubProtocol
import Foundation

/// 止めないもの（実機確認）の知らせ方（`docs/renewal/operations.md` の「通知」）。人が答えなくても先に進むので、見つけてすぐには知らせず、
/// 決めた時刻（1 日数回）ごとに、それまでにマージした epic のまだ答えていない実機確認を 1 通にまとめる。
///
/// 1 つの epic は 1 回だけ知らせる（答えていない項目を、時刻ごとに促し直さない）
struct VerificationDigest {
    var context: CommanderContext
    /// 知らせる時刻（`timeZone` の 0〜23 時）
    var hours: [Int]
    var timeZone: TimeZone

    /// 出来事の key（`notifications.json`）。epic ごとに 1 つ
    static func key(of epic: EpicFile) -> String {
        "verification/\(epic.repo)/\(epic.id)"
    }

    /// `now` までの、最後に知らせる時刻（今日か昨日の、決めた時刻のうち最も新しいもの）。決めた時刻が無ければ nil
    func latestSlot(atOrBefore now: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let hours = Set(hours.filter { (0...23).contains($0) }).sorted(by: >)
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            for hour in hours {
                if let slot = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day), slot <= now { return slot }
            }
        }
        return nil
    }

    /// 今知らせてよい epic: マージした epic のうち、最後に知らせる時刻より前にマージしたもの（その後にマージしたものは、次の時刻に回す）
    func due(_ epics: [EpicFile], now: Date) -> [EpicFile] {
        guard let slot = latestSlot(atOrBefore: now) else { return [] }
        return epics.filter { $0.stage == .merged && ($0.merge?.at ?? $0.updatedAt).date <= slot }
    }

    /// epic のまだ答えていない実機確認の項目の数（ゴールの完了の条件のうち、`verifications.json` に答えが無いもの）。
    /// ゴールを読めなければ、確かめられないので nil
    func unanswered(of epic: EpicFile) async throws(CommanderError) -> Int? {
        guard let goal = try await context.readable(GoalFile.self, at: StatePath.goal(epic.repo, epic.id)) else { return nil }
        let answers = try await context.readable(VerificationsFile.self, at: StatePath.verifications(epic.repo, epic.id))
        return goal.doneWhen.indices.filter { answers?.answer(VerificationTarget.itemID(at: $0)) == nil }.count
    }
}
