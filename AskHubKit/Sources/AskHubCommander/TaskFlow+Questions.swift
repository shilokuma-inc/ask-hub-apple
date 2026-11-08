import AskHubEpics
import AskHubProtocol
import Foundation

/// 実装の途中の質問（`docs/renewal/flows.md` の「実装の途中の質問」）。
///
/// 実装・直しのジョブが質問で終えたら（試行の `outputs.report.question`）、質問を `questions.json` に足す。
/// 答えを待つ間は、その epic の次のジョブを作らない（ユーザーの決定。ほかの epic は進める）。
/// 答えたら、回答の受け付け（`AnswerHandler`）が、質問したジョブと同じ種類の再開のジョブを作る
extension TaskFlow {
    /// Claude にコードを書かせるジョブ（実装の途中の質問をするもの）
    static let askingKinds: Set<JobKind> = [.implementTask, .fixTask, .fixFinalPullRequest]

    /// 質問で終えたジョブの質問を足し、答えを待っている質問があれば、次のジョブを作らずに返す。
    /// 答えた質問の再開のジョブが無ければ（回答の受け付けで作る前に止まった）作る。質問に関わることが無ければ nil（いつもどおり進める）
    func questions(of epic: EpicFile, jobs: [JobFile]) async throws(CommanderError) -> Advanced? {
        let parents = Set(jobs.flatMap(\.dependsOn))
        // 質問で終えたジョブは、答えるまで次のジョブ（再開のジョブ）を持たない
        let leaves = jobs.filter { Self.askingKinds.contains($0.kind) && $0.state == .succeeded && !parents.contains($0.id) }
        guard !leaves.isEmpty else { return nil }
        let path = StatePath.questions(epic.repo, epic.id)
        let read = try await context.read(QuestionsFile.self, at: path)
        let file = read ?? QuestionsFile(questions: [])
        var asked: [(job: JobFile, question: TaskOutputReport.Question)] = []
        for leaf in leaves where !file.questions.contains(where: { $0.job == leaf.id }) {
            if let question = try await succeededOutputs(of: leaf)?.report?.question { asked.append((leaf, question)) }
        }
        var advanced = Advanced()
        var latest = file
        do throws(QuestionFlow.ResultError) {
            for (job, question) in asked {
                latest = try QuestionFlow.ask(question, job: job.id, task: job.task, in: latest)
            }
        } catch {
            return Advanced(notes: ["epic \(epic.id) の実装の途中の質問を足せない（\(error)）"])
        }
        if latest != file {
            try await write(latest, replacing: read, of: epic)
            let added = latest.questions.filter { question in asked.contains { $0.job.id == question.job } }
            advanced.notes += added.map { question in
                let place = question.task.map { "タスク \($0) の実装" } ?? "最終 PR の直し"
                return "epic \(epic.id) の\(place)の途中で、Claude が人に聞いた（\(question.id)）。答えるまで、この epic は止めて待つ"
            }
        }
        // 答えた質問の再開のジョブ（同じ id で作るので、回答の受け付けで作っていれば 2 つにならない）
        for leaf in leaves {
            guard let question = latest.questions.first(where: { $0.job == leaf.id }), question.state == .answered,
                  let answer = question.answer else { continue }
            let resumption = try await context.resumption(of: leaf, question: question.id, answer: answer.intent, epic: epic)
            try await context.create(resumption)
            advanced.created.append(resumption)
        }
        let waiting = latest.questions.filter { $0.isDuringImplementation && [.open, .clarifying].contains($0.state) }
        guard !asked.isEmpty || !advanced.created.isEmpty || !waiting.isEmpty else { return nil }
        if !waiting.isEmpty {
            advanced.notes.append("epic \(epic.id) は、実装の途中の質問（\(waiting.map(\.id).joined(separator: "・"))）の答えを待つ")
        }
        return advanced
    }

    /// 質問の一覧を書く（無ければ作る）
    private func write(_ questions: QuestionsFile, replacing previous: QuestionsFile?, of epic: EpicFile) async throws(CommanderError) {
        guard let previous else {
            do {
                try await context.files.create(questions, at: StatePath.questions(epic.repo, epic.id), message: "実装の途中の質問を足す")
                return
            } catch {
                throw .files(error)
            }
        }
        try await context.write(questions, replacing: previous, of: epic, message: "実装の途中の質問を足す")
    }

    /// 答えで再開したジョブの元（入力に `question` を持たない、質問する前のジョブ）。答えで再開したジョブでなければ、そのジョブ
    static func original(of job: JobFile, in jobs: [JobFile]) -> JobFile {
        var current = job
        var seen: Set<ULID> = [job.id]
        while current.input?["question"] != nil, let parent = current.dependsOn.first, seen.insert(parent).inserted,
              let found = jobs.first(where: { $0.id == parent }), found.kind == job.kind {
            current = found
        }
        return current
    }
}

extension JobFile {
    /// 実装の途中の質問の答えで再開したジョブか（入力に `question` がある）。直しの回数には数えない
    var resumesQuestion: Bool { input?["question"] != nil }
}

extension CommanderContext {
    /// 実装の途中の質問の答えで、質問したジョブ（`asking`）を再開するジョブ。同じ種類で、`input` は元の `input` に `question` を足したもの、
    /// `origin` は答えの意図、`dependsOn` は質問したジョブ、Mac は質問した試行の Mac（手元の変更と会話が残っている）
    func resumption(of asking: JobFile, question: String, answer: IntentReference, epic: EpicFile) async throws(CommanderError) -> JobFile {
        var input = asking.input ?? [:]
        input["question"] = .string(question)
        let mac = try await succeededAttempt(of: asking)?.mac ?? asking.assignedMac ?? epic.mac ?? self.mac
        let spec = JobSpec(kind: asking.kind, mac: mac, needs: asking.needs, input: input, dependsOn: [asking.id])
        var job = job(spec, for: epic, origin: answer, seed: "\(asking.id)/\(question)")
        job.task = asking.task
        return job
    }
}
