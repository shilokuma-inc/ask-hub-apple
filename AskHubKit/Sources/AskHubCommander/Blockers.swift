import AskHubProtocol
import AskHubStateStore
import Foundation

/// 進行を止めているもの（`docs/renewal/operations.md` の「通知」）。人が動くまで先に進まないので、見つけたらすぐ知らせる
public struct Blocker: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// 質問が回答を待っている
        case question(String)
        /// 着手前の確認で 1 つの epic に収まらないと分かり、分け方の判断を待っている
        case split
        /// ゴールの確認と開始を待っている。`revised` は、人の指示で直したゴールか
        case start(revised: Bool)
        /// 最終 PR のレビューが通り、人が決めていない判断の確認とマージの承認を待っている。
        /// `decisions` は答えていない判断のカードの数、`revised` は人が頼んだ直しの後のレビューか
        case review(pullRequest: Int, decisions: Int, revised: Bool)
        /// 自動の対処を使い切ったか、自動では直せない失敗で、人の判断を待っている
        case job(JobKind)
        /// ジョブを持った Mac が、決めた時間より長く戻らない
        case macOffline(jobs: Int, seenAt: Timestamp)
    }

    /// まとめて 1 つの通知にする単位
    public enum Scope: Hashable, Sendable {
        case epic(RepositoryFullName, ULID)
        case mac(MacName)
    }

    /// 同じ出来事を見分ける文字列（`notifications.json` の `key`）。見直した質問・直したゴール・人が頼んだ直しの後の最終 PR・次の試行・
    /// Mac が戻った後のオフラインは、別の出来事として知らせ直す
    public var key: String
    public var scope: Scope
    public var reason: Reason

    public init(key: String, scope: Scope, reason: Reason) {
        self.key = key
        self.scope = scope
        self.reason = reason
    }
}

/// 状態リポジトリから、進行を止めているものを拾う。読めない（知らない版など）ファイルは、確かめられないので飛ばす
struct BlockerScan {
    var context: CommanderContext
    /// ジョブを持った Mac が、これより長く戻らなければ知らせる（閉じてすぐには知らせない）
    var macOfflineAfter: Duration

    /// ジョブを持っているとみなす状態（人に渡したジョブは、人の判断を待つ通知で知らせる）
    static let heldStates: Set<JobState> = [.assigned, .running, .paused]

    /// `epics` はジョブを見張る epic、`jobs` はその epic のジョブ（`JobSweep` で見直した後のもの）
    func scan(epics: [EpicFile], jobs: [JobFile]) async throws(CommanderError) -> [Blocker] {
        let jobsOfEpics = Dictionary(grouping: jobs) { Blocker.Scope.epic($0.repo, $0.epic) }
        var blockers: [Blocker] = []
        for epic in epics.sorted(by: { $0.id < $1.id }) {
            blockers += try await waiting(on: epic, jobs: jobsOfEpics[.epic(epic.repo, epic.id)] ?? [])
        }
        for job in jobs.sorted(by: { $0.id < $1.id }) where job.state == .waitingHuman {
            let key = "job/\(job.repo)/\(job.epic)/\(job.id)/\(job.attempts)"
            blockers.append(Blocker(key: key, scope: .epic(job.repo, job.epic), reason: .job(job.kind)))
        }
        return blockers + (try await offlineMacs(holding: jobs))
    }

    /// epic が人の返事を待っているもの（質問・分け方の判断・ゴールの確認と開始・最終 PR の確認とマージの承認）。`jobs` はその epic のジョブ
    private func waiting(on epic: EpicFile, jobs: [JobFile]) async throws(CommanderError) -> [Blocker] {
        let scope = Blocker.Scope.epic(epic.repo, epic.id)
        let base = "\(epic.repo)/\(epic.id)"
        switch epic.stage {
        case .asking:
            guard let file = try await readable(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id)) else { return [] }
            // 説明を求めて答えを待つ間は、版が変わらなくても説明の数で別の出来事にする（説明ができたら知らせ直す）
            return file.questions.filter { $0.state == .open }.map { question in
                let key = "question/\(base)/\(question.id)/\(question.version)/\(question.explanations.count)"
                return Blocker(key: key, scope: scope, reason: .question(question.id))
            }
        case .awaitingSplit:
            guard let readiness = try await readable(ReadinessFile.self, at: StatePath.readiness(epic.repo, epic.id)) else { return [] }
            return [Blocker(key: "split/\(base)/\(readiness.version)", scope: scope, reason: .split)]
        case .awaitingStart:
            guard let goal = try await readable(GoalFile.self, at: StatePath.goal(epic.repo, epic.id)) else { return [] }
            return [Blocker(key: "start/\(base)/\(goal.version)", scope: scope, reason: .start(revised: goal.version > 1))]
        case .reviewing:
            return try await awaitingMerge(epic, jobs: jobs)
        case .drafting, .checking, .running, .finalizing, .merged, .abandoned:
            return []
        }
    }

    /// 最終 PR のレビューが通り、人の確認とマージの承認を待っている（`reviewing`）。承認してマージが動き出したら、もう待っていない。
    /// 出来事は最後のレビューごとに分ける（人が頼んだ直しの後にまた待てば、直した head のレビューとして知らせ直す。直しで head が変わらなくても知らせる）
    private func awaitingMerge(_ epic: EpicFile, jobs: [JobFile]) async throws(CommanderError) -> [Blocker] {
        let chain = FinalChain(jobs: jobs)
        guard chain.endsWithReview, let review = chain.latestReview, review.state == .succeeded,
              let seen = chain.reviewed, seen.isValid else { return [] }
        let decisions: DecisionsFile?
        do {
            decisions = try await context.files.read(DecisionsFile.self, at: StatePath.decisions(epic.repo, epic.id))?.file
        } catch .unreadable {
            return []
        } catch {
            throw .files(error)
        }
        // マージの承認の前に答える判断のカード（`FinalMergeRule.canApprove` と同じ数え方。仕分ける前の仮決めも数える）
        let unanswered = decisions?.items.filter { $0.visible != false && $0.answer == nil }.count ?? 0
        let key = "review/\(epic.repo)/\(epic.id)/\(seen.head)/\(review.id)"
        let reason = Blocker.Reason.review(pullRequest: seen.pullRequest, decisions: unanswered, revised: chain.hasHumanFix)
        return [Blocker(key: key, scope: .epic(epic.repo, epic.id), reason: reason)]
    }

    /// ジョブを持ったまま、決めた時間より長く生きている印を書いていない Mac。
    /// 印の時刻を出来事に含めるので、同じ Mac でも、一度戻ってからまた止まれば知らせ直す
    private func offlineMacs(holding jobs: [JobFile]) async throws(CommanderError) -> [Blocker] {
        // マージの後の片付けは進行を止めないので、Mac が戻るのを待つだけにする（知らせない）
        let held = Dictionary(grouping: jobs.filter { Self.heldStates.contains($0.state) && $0.kind != .cleanUp }) { $0.assignedMac }
        let limit = Double(macOfflineAfter.components.seconds)
        var blockers: [Blocker] = []
        for (name, jobs) in held.sorted(by: { ($0.key?.rawValue ?? "") < ($1.key?.rawValue ?? "") }) {
            // 印が無い・読めない Mac は、いつから戻っていないかが分からないので知らせない
            guard let name, let mac = try await readable(MacFile.self, at: StatePath.mac(name)), mac.mac == name,
                  context.now().timeIntervalSince(mac.seenAt.date) > limit else { continue }
            let reason = Blocker.Reason.macOffline(jobs: jobs.count, seenAt: mac.seenAt)
            blockers.append(Blocker(key: "mac/\(name)/\(mac.seenAt)", scope: .mac(name), reason: reason))
        }
        return blockers
    }

    private func readable<File: StateFile>(_ type: File.Type, at path: String) async throws(CommanderError) -> File? {
        do {
            return try await context.files.read(File.self, at: path)?.file
        } catch .unreadable {
            return nil
        } catch {
            throw .files(error)
        }
    }
}
