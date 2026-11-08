import AskHubProtocol
import Foundation

/// 人が答えた、実装の途中の質問（`docs/renewal/flows.md` の「実装の途中の質問」）
public struct AnsweredQuestion: Equatable, Sendable {
    public var question: QuestionsFile.Question
    public var answer: QuestionsFile.Answer

    /// 実装の途中の質問で、答えがあるときだけ作れる
    public init?(_ question: QuestionsFile.Question) {
        guard question.isDuringImplementation, question.state == .answered, let answer = question.answer else { return nil }
        self.question = question
        self.answer = answer
    }

    /// Claude に渡す、質問と人の答え
    var text: String {
        let choice = answer.choice.map { "「\($0)」を選んだ" } ?? "選択肢の外の答え（補足に書いた）"
        let note = answer.note.isEmpty ? "" : "\n補足: \(answer.note)"
        return "\(PromptText.question(question))\n人の答え: \(choice)\(note)"
    }
}

/// 質問した会話を再開して、人の答えを渡す（`--resume`）。作業場所は質問したときのまま（手元の変更が残っている）
public struct ResumedTaskJob<Base: TaskJob>: TaskJob {
    public static var kind: JobKind { Base.kind }

    /// 質問した会話の id
    public var session: String
    public var answered: AnsweredQuestion
    /// 元のジョブと同じ（CI の直しなら、落ちた検証が通るまで done にさせない）
    public var failingAtStart: TaskReport.BuildKind?

    public init(session: String, answered: AnsweredQuestion, failingAtStart: TaskReport.BuildKind? = nil) {
        self.session = session
        self.answered = answered
        self.failingAtStart = failingAtStart
    }

    public var resume: String? { session }

    public var prompt: String {
        """
        人が、あなたの質問（\(answered.question.id)）に答えました。答えに沿って、質問する前に頼まれた作業を続けてください。
        作業フォルダは、質問したときのまま（あなたが書いた変更が残っています）です。

        ## 質問と人の答え
        \(UntrustedText.block("answer", answered.text))

        ## 進め方
        - 人の答え（選んだ選択肢と補足）に従う
        - 書き終えたら needsBuild で確かめ、通ってから done にする
        - done の decisions には、質問する前に決めたことも含めて書く
        - また人が決めないと進められない判断が出たら、needsQuestion で聞く
        """
    }
}

/// 質問した会話を続けられないときに、新しい会話で、元の依頼に実装の途中で人に聞いて決まったことを足して進めさせる。
///
/// - 作業場所が残っている（`keptChanges`）が、会話が残っていない・`--resume` が失敗した: 作業場所にある途中の変更から続けさせる
/// - 作業場所が残っていない（片付けられた・Mac が違う・質問の後にブランチが動いた）: 取り出し直したので、変更を初めからやり直させる
public struct AnsweredTaskJob<Base: TaskJob>: TaskJob {
    public static var kind: JobKind { Base.kind }

    public var base: Base
    /// 同じタスク（最終 PR の直しは、最終 PR の直しの質問）で、人が答えた質問（古い順）
    public var answers: [AnsweredQuestion]
    /// 作業フォルダに、質問する前に書いた途中の変更が残っているか
    public var keptChanges: Bool

    public init(base: Base, answers: [AnsweredQuestion], keptChanges: Bool) {
        self.base = base
        self.answers = answers
        self.keptChanges = keptChanges
    }

    public var resume: String? { nil }
    public var failingAtStart: TaskReport.BuildKind? { base.failingAtStart }

    public var prompt: String {
        let how = keptChanges
            ? "作業フォルダには、そのときに書いた途中の変更が残っています（前の会話は続けられませんでした）。変更を読み、次の答えに沿って、途中の変更から続けてください。"
            : "そのときの変更は作業フォルダに残っていないので、次の答えに沿って、初めから変更をやり直してください。"
        return """
        \(base.prompt)

        ## 実装の途中で人に聞いて決まったこと
        この作業は、前に途中で人に質問して止めたものです。\(how)

        \(UntrustedText.block("answer", answers.map(\.text).joined(separator: "\n\n")))
        """
    }
}

/// 答えで再開するジョブが読むもの
struct QuestionResumption {
    /// 再開のきっかけの質問と答え
    var answered: AnsweredQuestion
    /// 同じタスク（最終 PR の直しは、最終 PR の直しの質問）で人が答えた質問（古い順）。新しい会話で、まとめて渡す
    var answers: [AnsweredQuestion]
    /// 質問した試行を動かした Mac（手元の変更と会話は、その Mac にだけ残る）
    var mac: MacName
    /// 質問した会話の id。記録が無ければ nil
    var session: String?

    /// Claude に `base` を進めさせる（`run` は作業場所で Claude に頼むもの）。作業場所が質問したときのまま残っていれば（`kept`）、
    /// 質問した会話を再開して答えを渡す。会話を再開できなければ（会話の記録が無い・`--resume` が失敗した）、同じ再開を失敗し続けないよう、
    /// 新しい会話で、元の依頼と決まったことを渡す
    func answer<Base: TaskJob>(_ base: Base, kept: Bool, run: (any TaskJob) async -> TaskReply) async -> TaskReply {
        if kept, let session {
            let reply = await run(ResumedTaskJob<Base>(session: session, answered: answered, failingAtStart: base.failingAtStart))
            guard reply.couldNotResume else { return reply }
        }
        return await run(AnsweredTaskJob(base: base, answers: answers, keptChanges: kept))
    }
}

extension TaskReply {
    /// 質問した会話を再開できなかった（最初の呼び出しで、Claude の結果を何も受け取れずに想定外の失敗をした。会話が残っていないなど）。
    /// 時間切れ・利用上限・認証・障害は、再開できないのではないので含めない
    var couldNotResume: Bool {
        guard case let .failed(failure, run) = self else { return false }
        return run.session == nil && failure.failureClass == .unexpected
    }
}

extension TaskJobEnvironment {
    /// ジョブの入力の `question`（nil なら答えで再開するジョブでない）の答えと、質問した試行を読む。`task` は質問のタスク（最終 PR の直しは nil）。
    /// 質問が、このジョブの前のジョブ（`dependsOn`）の同じ種類・同じタスクの質問でない・答えが無いときは、試行の失敗として終える
    func resumption(of job: JobFile, question id: String?, task: String?) async throws(TaskJobExit) -> QuestionResumption? {
        guard let id else { return nil }
        let questions = try await read(QuestionsFile.self, at: StatePath.questions(job.repo, job.epic))?.questions ?? []
        guard let question = questions.first(where: { $0.id == id }) else { throw .fail(.unexpected, "質問 \(id) が無い") }
        guard let asking = question.job, job.dependsOn.contains(asking), question.task == task else {
            throw .fail(.unexpected, "質問 \(id) は、このジョブの前のジョブ（同じタスク）がした、実装の途中の質問でない")
        }
        guard let answered = AnsweredQuestion(question) else { throw .fail(.unexpected, "質問 \(id) に答えが無い") }
        let history = TaskHistory(context: context, repo: job.repo, epic: job.epic)
        guard let asked = try await history.asked(by: asking), asked.job.kind == job.kind else {
            throw .fail(.unexpected, "質問 \(id) をしたジョブ（\(asking)）に、質問で終えた \(job.kind.rawValue) の試行が無い")
        }
        let answers = questions.filter { $0.task == task }.compactMap(AnsweredQuestion.init)
        return QuestionResumption(answered: answered, answers: answers, mac: asked.attempt.mac, session: asked.attempt.claude?.session)
    }

    /// 質問した試行がこの Mac で動き、epic の作業場所が質問したときのままなら、取り出し直さずに返す（手元の変更を残す）。そうでなければ nil
    func keptTask(_ resumption: QuestionResumption?, job: JobFile, branches: TaskBranches) async throws(TaskJobExit) -> CheckedOutTask? {
        guard resumption?.mac == context.mac else { return nil }
        let git = git
        return try await workspace { () throws(WorkspaceError) in
            try await git.reuseTask(job.repo, epic: job.epic, branches: branches)
        }
    }
}

extension FinalJobEnvironment {
    /// 質問した試行がこの Mac で動き、epic の作業場所が質問したときのままなら、取り出し直さずに返す（手元の変更と base の取り込みの途中を残す）
    func keptEpic(_ resumption: QuestionResumption?, job: JobFile, branches: FinalBranches) async throws(TaskJobExit) -> CheckedOutEpic? {
        guard resumption?.mac == context.mac else { return nil }
        let git = git
        return try await tasks.workspace { () throws(WorkspaceError) in
            try await git.reuseEpic(job.repo, epic: job.epic, branches: branches)
        }
    }
}

extension TaskHistory {
    /// 質問で終えた試行（`outputs.report.question` がある成功の試行）と、そのジョブ。ジョブか試行が無ければ nil
    func asked(by id: ULID) async throws(TaskJobExit) -> (job: JobFile, attempt: AttemptFile)? {
        do {
            guard let job = try await context.read(JobFile.self, at: StatePath.job(repo, epic: epic, job: id)) else { return nil }
            let asked = try await attempts(of: job).filter { $0.outcome == .succeeded && $0.outputs?.report?.question != nil }
            return asked.max { $0.number < $1.number }.map { (job, $0) }
        } catch {
            throw .state(error)
        }
    }

    /// 答えで再開したジョブの元（入力に `question` を持たない、質問する前のジョブ）。答えで再開したジョブでなければ、そのジョブ。
    /// 直すことの読み方（`dependsOn` のレビュー・`origin` の人の意図）は、元のジョブで決まる
    func original(of job: JobFile) async throws(TaskJobExit) -> JobFile {
        var current = job
        var seen: Set<ULID> = [job.id]
        while current.input?["question"] != nil, let parent = current.dependsOn.first, seen.insert(parent).inserted {
            let found: JobFile?
            do {
                found = try await context.read(JobFile.self, at: StatePath.job(repo, epic: epic, job: parent))
            } catch {
                throw .state(error)
            }
            guard let found, found.kind == job.kind else { break }
            current = found
        }
        return current
    }
}
