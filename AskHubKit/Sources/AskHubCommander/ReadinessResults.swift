import AskHubClaude
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import Foundation

// MARK: - 着手前の確認

extension ClaudeJobRunner {
    /// 着手前の確認の結果から、状態リポジトリに書くもの
    enum ReadinessResult {
        case ready(GoalFile)
        case moreQuestions(QuestionFlow.Change)
        case tooLarge
    }

    /// 依頼と、人が決めたことの一式を確かめる。進めてよければゴールを作り、追加の質問が要れば回答に戻し、
    /// 1 つの epic に収まらなければ分け方の判断を待つ
    func checkReadiness(_ job: JobFile, epic: EpicFile) async throws(CommanderError) -> ClaudeJobOutcome {
        guard epic.stage == .checking else { return .discarded("epic はもう着手前の確認の段階でない", nil) }
        guard let questions = try await questionsFile(of: epic) else { return Self.missingQuestions }
        // 前の試行で追加の質問まで書き、回答に戻す前に止まった。続きを書いて終える
        if !questions.questions.allSatisfy(\.state.isSettled), let origin = job.origin {
            try await context.lock.withLock { () throws(CommanderError) in
                try await context.perform([.reopen], for: epic, origin: origin, after: [job.id])
            }
            return .discarded("前の試行で足した追加の質問の続きを書いた（回答に戻した）", nil)
        }
        guard let envelope = try await envelope(of: epic.origin), let request = try? RequestIntent(envelope: envelope) else {
            return .failed(AttemptFailure(failureClass: .unexpected, message: "元の依頼を読めない・署名が合わない"), nil)
        }
        let placed: PlacedAttachments?
        do throws(WorkspaceError) {
            placed = try await placeAttachments(of: request, for: job)
        } catch {
            return .failed(error.attemptFailure, nil)
        }
        // 「このまま 1 つで進める」と決めた後は、追加の質問に答えた後の確認でも、大きすぎるとは返させない
        let previous = try await context.read(ReadinessFile.self, at: StatePath.readiness(epic.repo, epic.id))
        let proceeding = job.input?["proceed"] == .bool(true) || previous?.proceeding == true
        let claudeJob = CheckReadinessJob(
            title: request.title,
            body: request.body,
            questions: questions,
            attachments: placed?.paths ?? [],
            proceeding: proceeding
        )
        switch await ask(claudeJob, for: epic, attachments: placed?.directory) {
        case let .failed(failure, session):
            return .failed(failure, session)
        case let .answered(output, session):
            let result: ReadinessResult
            do throws(QuestionFlow.ResultError) {
                result = try Self.result(of: output, for: claudeJob)
            } catch {
                return .failed(AttemptFailure(failureClass: .unexpected, message: "着手前の確認の結果を当てられない（\(error)）"), session)
            }
            let readiness = Self.readiness(of: output, for: claudeJob, at: context.timestamp)
            // 読み直してから書き終えるまでに、人の答え直しが割り込まないようにする
            return try await context.lock.withLock { () throws(CommanderError) -> ClaudeJobOutcome in
                guard try await stillWanted(job, stages: [.checking]) != nil, try await questionsFile(of: epic) == questions else {
                    return .discarded("頼んだ後に epic か質問の一覧が変わった", session)
                }
                try await write(result, readiness: readiness, questions: questions, of: epic, by: job)
                return .written(session)
            }
        }
    }

    /// 書く確認の結果。版は書くときに、前の結果の次にする
    static func readiness(of output: CheckReadinessJob.Output, for job: CheckReadinessJob, at time: Timestamp) -> ReadinessFile {
        let parts = output.verdict == .tooLarge ? output.split ?? [] : []
        return ReadinessFile(
            version: 1,
            verdict: ReadinessVerdict(output.verdict),
            reason: output.reason,
            split: parts.map { ReadinessFile.Part(title: $0.title, summary: $0.summary) },
            round: job.nextRound - 1,
            proceeding: job.proceeding ? true : nil,
            checkedAt: time
        )
    }

    static func result(
        of output: CheckReadinessJob.Output,
        for job: CheckReadinessJob
    ) throws(QuestionFlow.ResultError) -> ReadinessResult {
        switch output.verdict {
        case .ready:
            guard let draft = output.goal else { throw .invalid(["verdict が ready なのに、goal が無い"]) }
            return .ready(try GoalFlow.goal(from: draft, questions: job.questions, version: 1))
        case .moreQuestions:
            return .moreQuestions(try QuestionFlow.append(output.questions ?? [], round: job.nextRound, to: job.questions))
        case .tooLarge:
            return .tooLarge
        }
    }

    /// 着手前の確認の結果を書く。確認の結果を先に書き、epic の段階を最後に変える。
    /// 追加の質問は、質問の一覧を書いてから回答に戻す（その間に止まったら、次の試行が続きを書く）
    private func write(
        _ result: ReadinessResult,
        readiness: ReadinessFile,
        questions: QuestionsFile,
        of epic: EpicFile,
        by job: JobFile
    ) async throws(CommanderError) {
        try await replace(at: StatePath.readiness(epic.repo, epic.id), message: "着手前の確認の結果を書く") { (previous: ReadinessFile?) in
            var next = readiness
            next.version = (previous?.version ?? 0) + 1
            return next
        }
        switch result {
        case let .ready(goal):
            // 版は前のゴールの次にし、Discussion の写しのコメントは引き継ぐ
            try await replace(at: StatePath.goal(epic.repo, epic.id), message: "ゴールを作る") { (previous: GoalFile?) in
                var next = goal
                next.version = (previous?.version ?? 0) + 1
                next.comment = previous?.comment
                return next
            }
            try await context.setStage(.awaitingStart, of: epic, from: [.checking])
        case let .moreQuestions(change):
            try await context.write(change.questions, replacing: questions, of: epic, message: "追加の質問を足す")
            if let origin = job.origin { try await context.perform(change.effects, for: epic, origin: origin, after: [job.id]) }
        case .tooLarge:
            try await context.setStage(.awaitingSplit, of: epic, from: [.checking])
        }
    }
}

// MARK: - ゴールの修正

extension ClaudeJobRunner {
    /// 人の指示でゴールを直す。人が決めたことを変える指示は反映せず、`notApplied` に書く
    func reviseGoal(_ job: JobFile, epic: EpicFile) async throws(CommanderError) -> ClaudeJobOutcome {
        guard let instruction = Self.input("instruction", of: job, as: String.self),
              let version = Self.input("goalVersion", of: job, as: Int.self) else {
            return Self.malformedInput(job)
        }
        guard epic.stage == .awaitingStart else { return .discarded("epic はもうゴールを直せる段階でない", nil) }
        let goalPath = StatePath.goal(epic.repo, epic.id)
        guard let goal = try await context.read(GoalFile.self, at: goalPath), goal.version == version else {
            return .discarded("頼んだ後にゴールが直された", nil)
        }
        guard let questions = try await questionsFile(of: epic) else { return Self.missingQuestions }
        switch await ask(ReviseGoalJob(goal: goal, questions: questions, instruction: instruction), for: epic) {
        case let .failed(failure, session):
            return .failed(failure, session)
        case let .answered(output, session):
            var revised: GoalFile
            do throws(QuestionFlow.ResultError) {
                revised = try GoalFlow.goal(from: output.goal, questions: questions, version: version + 1, comment: goal.comment)
            } catch {
                return .failed(AttemptFailure(failureClass: .unexpected, message: "直したゴールを作れない（\(error)）"), session)
            }
            revised.notApplied = output.notApplied.isEmpty ? nil : output.notApplied
            let goalToWrite = revised
            return try await context.lock.withLock { () throws(CommanderError) -> ClaudeJobOutcome in
                guard try await stillWanted(job, stages: [.awaitingStart]) != nil, try await questionsFile(of: epic) == questions else {
                    return .discarded("頼んだ後に epic が先に進んだ・回答に戻った", session)
                }
                let written = try await write(goalToWrite, replacing: version, at: goalPath)
                return written ? .written(session) : .discarded("頼んだ後にゴールが直された", session)
            }
        }
    }

    /// ゴールが `version` のままなら書く
    private func write(_ goal: GoalFile, replacing version: Int, at path: String) async throws(CommanderError) -> Bool {
        var written = false
        do {
            try await context.files.update(GoalFile.self, at: path, message: "ゴールを直す") {
                guard $0.version == version else { return false }
                $0 = goal
                written = true
                return true
            }
        } catch {
            throw .files(error)
        }
        return written
    }
}

// MARK: - 共通

extension ClaudeJobRunner {
    /// 質問の一覧。質問が 1 つも無かった依頼でも、質問づくりのときに空の一覧を作るので、無ければ状態が壊れている
    func questionsFile(of epic: EpicFile) async throws(CommanderError) -> QuestionsFile? {
        try await context.read(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id))
    }

    /// 質問の一覧が無い（回答を欠いたゴールを作らないよう、止めて人に渡す）
    static let missingQuestions = ClaudeJobOutcome.failed(AttemptFailure(failureClass: .unexpected, message: "質問の一覧が無い"), nil)

    /// ファイルが無ければ作り、あれば前の中身から作った新しい中身で置き換える
    func replace<File: StateFile>(at path: String, message: String, next: @escaping (File?) -> File) async throws(CommanderError) {
        do {
            if try await context.files.read(File.self, at: path) == nil {
                try await context.files.create(next(nil), at: path, message: message)
            } else {
                try await context.files.update(File.self, at: path, message: message) {
                    $0 = next($0)
                    return true
                }
            }
        } catch .alreadyExists {
            // 読んだ後に作られた。次の周でやり直す
            throw .changedWhileProcessing(path)
        } catch {
            throw .files(error)
        }
    }
}

extension ReadinessVerdict {
    init(_ verdict: CheckReadinessJob.Verdict) {
        switch verdict {
        case .ready: self = .ready
        case .moreQuestions: self = .moreQuestions
        case .tooLarge: self = .tooLarge
        }
    }
}
