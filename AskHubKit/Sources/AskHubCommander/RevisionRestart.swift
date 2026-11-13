import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 見直している（`revising`）のに、今の質問と依存先の版と回答（basis）で見直すジョブが動いていない・人を待っていない質問の、
/// 見直しを頼み直す（`docs/renewal/flows.md` の「司令塔の動き」）。
///
/// 見直しの結果は、頼んだ後に basis が変わっていれば捨てる（`QuestionFlow.revise` の `stale`）。そのとき新しいジョブが無いと、
/// 質問は見直しのまま止まり、人には答えられない（2026-11-13、同じ回答が 2 回届いて回答の意図が差し替わり、見直しの結果が捨てられた）。
///
/// ジョブの見回り（`JobSweep`）の後に、開始の前の epic ごとに行う。まず見回りの写しで探し、見つけたら人の意図の処理と同じ排他の中で、
/// 元の置き場所から読み直して決め直してから作る（写しの後に作られたジョブと重ねないように）。
/// 頼み直すジョブの id は、ふつうに頼んだジョブと別にし、同じ basis では 1 つしか作らない（頼み直したジョブも止まったら、作り直し続けない）
public struct RevisionRestart: Sendable {
    public var context: CommanderContext

    public init(context: CommanderContext) {
        self.context = context
    }

    /// 頼み直した結果
    public struct Restarted: Sendable, Equatable {
        /// 作ったジョブ（同じ周で引き受けられるよう、ジョブの一覧に足す）
        public var created: [JobFile] = []
        /// ログに出すこと（頼み直せない理由）
        public var notes: [String] = []
    }

    /// `epics` はジョブを見張る epic、`jobs` はそのジョブ（見直した後のもの）、`reader` は見回りで読んだ写し（無ければ元の置き場所から読む）。
    /// 1 つの epic で失敗しても、ほかの epic は確かめる。人が一時停止した epic は、再開するまで頼み直さない
    public func restart(epics: [EpicFile], jobs: [JobFile], reading reader: CommanderContext? = nil) async -> Restarted {
        var restarted = Restarted()
        let planning = epics.filter { CommanderContext.planningStages.contains($0.stage) && $0.pause == nil }
        for epic in planning.sorted(by: { $0.id < $1.id }) {
            let own = jobs.filter { $0.repo == epic.repo && $0.epic == epic.id }
            do {
                let path = StatePath.questions(epic.repo, epic.id)
                guard let seen = try await (reader ?? context).readable(QuestionsFile.self, at: path),
                      !QuestionFlow.stalledRevisions(in: seen, pending: Self.pending(own)).isEmpty else {
                    continue
                }
                let step = try await context.lock.withLock { () throws(CommanderError) -> Restarted in
                    try await restart(epic)
                }
                restarted.created += step.created
                restarted.notes += step.notes
            } catch {
                restarted.notes.append("epic \(epic.id) の見直しを頼み直せなかった（\(error)）。次の周でやり直す")
            }
        }
        return restarted
    }

    /// 1 つの epic の止まった見直しを、元の置き場所から読み直して頼み直す。`context.lock` の中で呼ぶ
    func restart(_ seen: EpicFile) async throws(CommanderError) -> Restarted {
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(seen.repo, seen.id)),
              CommanderContext.planningStages.contains(epic.stage), epic.pause == nil,
              let questions = try await context.read(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id)) else {
            return Restarted()
        }
        let list = try await context.jobList(epic.repo, epic: epic.id)
        // 読めないジョブが見直しのジョブかもしれないので、確かめられるまで頼み直さない（新しい司令塔が扱う）
        guard list.unreadable.isEmpty else {
            return Restarted(notes: ["epic \(epic.id) に読めないジョブがあるので、止まった見直しを頼み直さない"])
        }
        var restarted = Restarted()
        for case let .revise(question, basis) in QuestionFlow.stalledRevisions(in: questions, pending: Self.pending(list.jobs)) {
            guard let origin = QuestionFlow.revisionOrigin(of: question, in: questions) ?? epic.origin else {
                restarted.notes.append("epic \(epic.id) の質問 \(question) は見直しのまま止まっているが、頼み直す元の人の意図が分からない")
                continue
            }
            let job = context.revisionJob(question, basis: basis, for: epic, origin: origin, restart: true)
            guard !list.jobs.contains(where: { $0.id == job.id }) else {
                restarted.notes.append("epic \(epic.id) の質問 \(question) は、頼み直した見直し（\(job.id)）も終わったが、見直しのまま止まっている")
                continue
            }
            try await context.create(job)
            restarted.created.append(job)
        }
        return restarted
    }

    /// 終わっていない（動いている・人を待っている）見直しのジョブの、質問と basis
    static func pending(_ jobs: [JobFile]) -> [(question: String, basis: RevisionBasis)] {
        jobs.compactMap { job in
            guard job.kind == .reviseQuestion, JobFile.openStates.contains(job.state),
                  let question = ClaudeJobRunner.input("question", of: job, as: String.self),
                  let basis = ClaudeJobRunner.input("basis", of: job, as: RevisionBasis.self) else {
                return nil
            }
            return (question, basis)
        }
    }
}
