import AskHubProtocol
import Foundation

/// ワーカーが、自分宛てのジョブから今引き受けるものを選ぶ
public enum JobPicker {
    /// 引き受けてよいジョブを、引き受ける順に返す。
    ///
    /// - 自分宛てで `assigned` のもの、次に試してよい時刻を過ぎたもの、先に終わっている必要のあるジョブがすべて成功したものだけ
    /// - Mac ごとの同時の上限（Claude・ビルド）を、今実行中の自分のジョブと合わせて超えない
    /// - 人が待っているジョブ（説明・質問の見直しなど）を、実装のループより先にする
    public static func pick(from jobs: [JobFile], for mac: MacName, capacity: MacFile.Capacity, now: Date) -> [JobFile] {
        let succeeded = Set(jobs.filter { $0.state == .succeeded }.map(\.id))
        let mine = jobs.filter { $0.assignedMac == mac }
        var claudeInUse = mine.filter { $0.state == .running && $0.needs.claude }.count
        var buildInUse = mine.filter { $0.state == .running && $0.needs.build }.count
        let candidates = mine
            .filter { job in
                job.state == .assigned
                    && (job.nextRunAt.map { $0.date <= now } ?? true)
                    && job.dependsOn.allSatisfy(succeeded.contains)
            }
            .sorted { lhs, rhs in
                (priority(lhs.kind), lhs.createdAt, lhs.id) < (priority(rhs.kind), rhs.createdAt, rhs.id)
            }
        var picked: [JobFile] = []
        for job in candidates {
            let needsClaude = job.needs.claude ? 1 : 0
            let needsBuild = job.needs.build ? 1 : 0
            guard claudeInUse + needsClaude <= capacity.claude, buildInUse + needsBuild <= capacity.build else { continue }
            claudeInUse += needsClaude
            buildInUse += needsBuild
            picked.append(job)
        }
        return picked
    }

    /// 小さいほど先。人が待っているもの → 最終 PR の対処 → 実装 → 片付け
    static func priority(_ kind: JobKind) -> Int {
        switch kind {
        case .notify, .explain, .reviseQuestion, .reviseGoal:
            0
        case .makeQuestions, .checkReadiness:
            1
        case .fixFinalPullRequest, .rerunChecks, .mergeFinalPullRequest, .openFinalPullRequest, .verifyBeforeFinal,
             .classifyDecisions, .captureScreenshots:
            2
        case .prepareWorkspace, .implementTask, .fixTask, .integrateDevelop:
            3
        case .cleanUp:
            4
        }
    }
}
