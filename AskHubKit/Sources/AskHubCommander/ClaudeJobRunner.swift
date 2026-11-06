import AskHubClaude
import AskHubEpics
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation

/// Claude を呼ぶジョブを 1 つ実行した結果
public enum ClaudeJobOutcome: Equatable, Sendable {
    /// 結果を状態リポジトリに書いた
    case written(ClaudeSession)
    /// 頼んだ後に状態が変わった（人が答え直した・epic が先に進んだなど）ので、結果を捨てた。ジョブは成功として終える
    case discarded(String, ClaudeSession?)
    /// Claude の呼び出しや作業場所の用意に失敗した。試行の失敗として書き、失敗の区分に沿って扱う
    case failed(AttemptFailure, ClaudeSession?)
}

/// 常時オンの Mac で、Claude を呼ぶ段階 2 のジョブ（質問づくり・説明・見直し・着手前の確認・ゴールの修正）を 1 つ実行し、
/// 結果を状態リポジトリに書く（`docs/renewal/flows.md` の「質問づくり・説明・確かめを Claude に頼むとき」）。
///
/// 結果を書く前に今の状態を読み直し、頼んだ後に変わっていれば捨てる。書く順は、ジョブ → 質問の一覧・ゴール → epic
public struct ClaudeJobRunner: Sendable {
    public var context: CommanderContext
    public var client: ClaudeClient
    public var workspace: any RepositoryWorkspace
    /// 受け付けた人の意図を読み直すときに、署名を確かめる（有効期間は見ない。受け付けたときに確かめている）
    public var verifier: IntentVerifier

    public init(context: CommanderContext, client: ClaudeClient, workspace: any RepositoryWorkspace, verifier: IntentVerifier) {
        self.context = context
        self.client = client
        self.workspace = workspace
        var verifier = verifier
        verifier.maximumAge = .greatestFiniteMagnitude
        self.verifier = verifier
    }

    public func run(_ job: JobFile) async throws(CommanderError) -> ClaudeJobOutcome {
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(job.repo, job.epic)) else {
            return .discarded("epic が無い", nil)
        }
        guard CommanderContext.planningStages.contains(epic.stage) else {
            return .discarded("epic はもう開始した・やめた（今は \(epic.stage.rawValue)）", nil)
        }
        switch job.kind {
        case .makeQuestions: return try await makeQuestions(job, epic: epic)
        case .explain: return try await explain(job, epic: epic)
        case .reviseQuestion: return try await reviseQuestion(job, epic: epic)
        case .checkReadiness: return try await checkReadiness(job, epic: epic)
        case .reviseGoal: return try await reviseGoal(job, epic: epic)
        default: return .failed(AttemptFailure(failureClass: .unexpected, message: "\(job.kind.rawValue) は Claude のジョブとして扱えない"), nil)
        }
    }

    // MARK: - 共通

    /// 作業場所を用意して Claude に頼む
    func ask<Job: ClaudeJob>(_ claudeJob: Job, for epic: EpicFile, attachments: URL? = nil) async -> ClaudeReply<Job.Output> {
        let prepared: PreparedWorkspace
        do {
            prepared = try await workspace.prepare(epic.repo)
        } catch {
            return .failed(error.attemptFailure, nil)
        }
        return await claudeJob.ask(
            using: client,
            repository: epic.repo,
            facts: prepared.facts,
            workingDirectory: prepared.directory,
            additionalDirectories: attachments.map { [$0] } ?? [],
            now: context.now
        )
    }

    /// 受け付けた人の意図を読み直す（署名を確かめてから使う）
    func envelope(of origin: IntentReference?) async throws(CommanderError) -> IntentEnvelope? {
        guard let origin else { return nil }
        let blob: StoredBlob?
        do {
            blob = try await context.store.read(StatePath.intent(device: origin.keyId, nonce: origin.nonce))
        } catch {
            throw .store(error)
        }
        guard let data = blob?.data, let value = try? JSONValue(parsing: data),
              let envelope = try? verifier.verify(stored: value, now: context.now()),
              envelope.keyId == origin.keyId, envelope.nonce == origin.nonce else {
            return nil
        }
        return envelope
    }

    /// 結果を書く直前に読み直した epic。epic の段階が `stages` から外れた・ジョブが取り消されたときは nil（結果を捨てる）。
    /// `context.lock` の中で呼ぶ
    func stillWanted(_ job: JobFile, stages: Set<EpicStage>) async throws(CommanderError) -> EpicFile? {
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(job.repo, job.epic)), stages.contains(epic.stage),
              try await context.read(JobFile.self, at: StatePath.job(job.repo, epic: job.epic, job: job.id))?.state != .canceled else {
            return nil
        }
        return epic
    }

    /// ジョブの入力の欄を、決まった型で読む
    static func input<Value: Decodable>(_ name: String, of job: JobFile, as type: Value.Type) -> Value? {
        guard let value = job.input?[name] else { return nil }
        return try? JSONDecoder().decode(Value.self, from: CanonicalJSON.data(for: value))
    }

    static func malformedInput(_ job: JobFile) -> ClaudeJobOutcome {
        .failed(AttemptFailure(failureClass: .unexpected, message: "\(job.kind.rawValue) のジョブの入力の形が違う"), nil)
    }
}

// MARK: - 質問づくり・説明・見直し

extension ClaudeJobRunner {
    /// 依頼から質問を作り、epic を回答の待ちにする（質問が無ければ着手前の確認へ）
    func makeQuestions(_ job: JobFile, epic: EpicFile) async throws(CommanderError) -> ClaudeJobOutcome {
        guard epic.stage == .drafting else { return .discarded("epic はもう質問づくりの段階でない", nil) }
        guard let envelope = try await envelope(of: job.origin), let request = try? RequestIntent(envelope: envelope) else {
            return .failed(AttemptFailure(failureClass: .unexpected, message: "元の依頼を読めない・署名が合わない"), nil)
        }
        let placed: PlacedAttachments?
        do throws(WorkspaceError) {
            placed = try await placeAttachments(of: request, for: job)
        } catch {
            return .failed(error.attemptFailure, nil)
        }
        let claudeJob = MakeQuestionsJob(title: request.title, body: request.body, attachments: placed?.paths ?? [])
        switch await ask(claudeJob, for: epic, attachments: placed?.directory) {
        case let .failed(failure, session):
            return .failed(failure, session)
        case let .answered(output, session):
            let change: QuestionFlow.Change
            do throws(QuestionFlow.ResultError) {
                change = try QuestionFlow.start(output.questions)
            } catch {
                return .failed(AttemptFailure(failureClass: .unexpected, message: "質問の一覧を作れない（\(error)）"), session)
            }
            return try await context.lock.withLock { () throws(CommanderError) -> ClaudeJobOutcome in
                guard try await stillWanted(job, stages: [.drafting]) != nil else {
                    return .discarded("頼んだ後に epic がやめられた・先に進んだ", session)
                }
                try await write(change, summary: output.summary, of: epic, by: job)
                return .written(session)
            }
        }
    }

    /// 質問づくりの結果を書く。書く順は、質問の一覧 → ジョブ → epic
    private func write(_ change: QuestionFlow.Change, summary: String, of epic: EpicFile, by job: JobFile) async throws(CommanderError) {
        let written = try await createQuestions(change.questions, of: epic)
        // 前の周で質問の一覧まで書いていたら、そのときの一覧から進め方を決める
        let effects = written == change.questions ? change.effects : (written.questions.isEmpty ? [.checkReadiness] : [])
        if effects.contains(.checkReadiness), let origin = job.origin {
            try await context.create(context.claudeJob(.checkReadiness, for: epic, origin: origin, seed: "", input: [:], after: [job.id]))
        }
        try await context.setStage(effects.contains(.checkReadiness) ? .checking : .asking, of: epic, from: [.drafting]) {
            $0.summary = summary
        }
    }

    /// 人の問いに説明を書く
    func explain(_ job: JobFile, epic: EpicFile) async throws(CommanderError) -> ClaudeJobOutcome {
        guard let question = Self.input("question", of: job, as: String.self),
              let asked = Self.input("asked", of: job, as: IntentReference.self) else {
            return Self.malformedInput(job)
        }
        guard let questions = try await context.read(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id)) else {
            return .discarded("質問の一覧が無い", nil)
        }
        switch await ask(ExplainJob(questions: questions, question: question, asked: asked), for: epic) {
        case let .failed(failure, session):
            return .failed(failure, session)
        case let .answered(output, session):
            return try await apply(to: epic, by: job, session: session) { latest throws(QuestionFlow.ResultError) in
                try QuestionFlow.explain(question, asked: asked, text: output.text, rewrite: output.rewrite, in: latest)
            }
        }
    }

    /// 依存先が決まった質問を見直す
    func reviseQuestion(_ job: JobFile, epic: EpicFile) async throws(CommanderError) -> ClaudeJobOutcome {
        guard let question = Self.input("question", of: job, as: String.self),
              let basis = Self.input("basis", of: job, as: RevisionBasis.self) else {
            return Self.malformedInput(job)
        }
        guard let questions = try await context.read(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id)) else {
            return .discarded("質問の一覧が無い", nil)
        }
        let claudeJob = ReviseQuestionJob(questions: questions, question: question, basis: basis)
        switch await ask(claudeJob, for: epic) {
        case let .failed(failure, session):
            return .failed(failure, session)
        case let .answered(output, session):
            let outcome = claudeJob.outcome(of: output)
            return try await apply(to: epic, by: job, session: session) { latest throws(QuestionFlow.ResultError) in
                try QuestionFlow.revise(question, basis: basis, outcome: outcome, in: latest)
            }
        }
    }

    /// 今の質問の一覧を読み直して結果を当て、司令塔がすることを行ってから書く。頼んだ後に変わっていれば捨てる。
    /// 書く順は、回答の受け付けと同じく ジョブ → epic → 質問の一覧。作るジョブは、このジョブが成功してから動く
    private func apply(
        to epic: EpicFile,
        by job: JobFile,
        session: ClaudeSession,
        _ change: (QuestionsFile) throws(QuestionFlow.ResultError) -> QuestionFlow.Change
    ) async throws(CommanderError) -> ClaudeJobOutcome {
        try await context.lock.withLock { () throws(CommanderError) -> ClaudeJobOutcome in
            guard try await stillWanted(job, stages: CommanderContext.planningStages) != nil else {
                return .discarded("頼んだ後に epic が開始した・やめられた", session)
            }
            guard let latest = try await context.read(QuestionsFile.self, at: StatePath.questions(epic.repo, epic.id)) else {
                return .discarded("質問の一覧が無い", session)
            }
            let result: QuestionFlow.Change
            do throws(QuestionFlow.ResultError) {
                result = try change(latest)
            } catch .stale {
                return .discarded("頼んだ後に質問の一覧が変わった", session)
            } catch {
                return .failed(AttemptFailure(failureClass: .unexpected, message: "Claude の結果を当てられない（\(error)）"), session)
            }
            if let origin = job.origin { try await context.perform(result.effects, for: epic, origin: origin, after: [job.id]) }
            try await context.write(result.questions, replacing: latest, of: epic, message: "Claude の結果を書く")
            return .written(session)
        }
    }

    /// 質問の一覧を作る。前の周で作っていれば、そのときの一覧を返す
    private func createQuestions(_ questions: QuestionsFile, of epic: EpicFile) async throws(CommanderError) -> QuestionsFile {
        let path = StatePath.questions(epic.repo, epic.id)
        do {
            return try await context.files.create(questions, at: path, message: "質問を作る").file
        } catch .alreadyExists {
            return try await context.read(QuestionsFile.self, at: path) ?? questions
        } catch {
            throw .files(error)
        }
    }

    struct PlacedAttachments {
        var directory: URL
        var files: [URL]

        var paths: [String] { files.map(\.path) }
    }

    /// 依頼の添付を、Claude が読んでよいフォルダに置く。添付が無ければ nil。
    /// 名前が重なってもよいように、番号ごとのフォルダに置く（`<フォルダ>/<番号>/<名前>`）。
    /// 受け付けた後に置き換えられていないよう、置く前に大きさとハッシュを署名した依頼と照らし合わせる
    func placeAttachments(of request: RequestIntent, for job: JobFile) async throws(WorkspaceError) -> PlacedAttachments? {
        guard !request.attachments.isEmpty else { return nil }
        let directory = try await workspace.attachmentsDirectory(for: job.id)
        var files: [URL] = []
        for attachment in request.attachments {
            let path = StatePath.attachment(device: request.intent.keyId, nonce: request.intent.nonce, number: attachment.number)
            let blob: StoredBlob?
            do {
                blob = try await context.store.read(path)
            } catch {
                throw WorkspaceError.unavailable("添付 \(attachment.number) を読めない（\(error)）")
            }
            guard let data = blob?.data else { throw WorkspaceError.failed("添付 \(attachment.number) が無い") }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard data.count == attachment.size, digest == attachment.sha256 else {
                throw WorkspaceError.failed("添付 \(attachment.number) の大きさかハッシュが、依頼と合わない")
            }
            // 名前は、受け付けたときにパスの区切りを含まないことを確かめている。前の周で置いていれば上書きする
            let folder = directory.appendingPathComponent(String(attachment.number), isDirectory: true)
            let file = folder.appendingPathComponent(attachment.name)
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try data.write(to: file, options: .atomic)
            } catch {
                throw .failed("添付 \(attachment.number) を置けない（\(error.localizedDescription)）")
            }
            files.append(file)
        }
        return PlacedAttachments(directory: directory, files: files)
    }
}
