import AskHubProtocol
import AskHubStateStore
import Foundation

/// 状態リポジトリから読んだファイルの一式。画面用のモデルに変える前の形（`docs/renewal/protocol.md`）
struct StateDocuments {
    struct EpicDocuments {
        var epic: EpicFile
        var questions: QuestionsFile?
        var goal: GoalFile?
        var readiness: ReadinessFile?
        /// ジョブ。終わった（マージした・やめた）epic のものは読まない
        var jobs: [JobFile] = []
        /// 試行（古い順）。人の対応を待っているジョブはすべて、動いているジョブは最後の 1 つだけ
        var attempts: [ULID: [AttemptFile]] = [:]
    }

    /// この端末が送った人の意図と、司令塔が処理した記録
    struct SentIntent {
        var envelope: IntentEnvelope
        /// 処理した記録。司令塔がまだ処理していなければ nil
        var consumed: ConsumedIntentFile?
    }

    var repositories: [RepositoryFile] = []
    var epics: [EpicDocuments] = []
    var macs: [MacFile] = []
    var commander: CommanderFile?
    /// 新しい順
    var sentIntents: [SentIntent] = []
    var failures: [SourceFailure] = []
}

/// 状態リポジトリを読む。読めないファイルは飛ばして `failures` に入れ、ほかは読み続ける
struct StateReader {
    let store: any StateStore
    let device: KeyID
    /// 処理の結果を出す、送った意図の件数（新しい順）
    var sentIntentLimit = 20

    /// ワーカーの生きている印を置くディレクトリ（`macs/<mac>.json`）
    static let macsDirectory = "macs"
    /// ジョブを読まない epic の段階。終わった epic のジョブは人の対応を待たないので、増え続ける分を読まずに済ませる
    static let finishedStages: Set<EpicStage> = [.merged, .abandoned]

    private var files: StateFileStore { StateFileStore(store: store) }

    func read() async throws(StateStoreError) -> StateDocuments {
        var documents = StateDocuments()
        for repo in try await repositories() {
            if let file = await read(RepositoryFile.self, at: StatePath.repository(repo), into: &documents) {
                documents.repositories.append(file)
            }
            for name in try await directories(StatePath.epics(repo)) {
                guard let id = ULID(rawValue: name) else {
                    continue
                }
                if let epic = await readEpic(id, of: repo, into: &documents) {
                    documents.epics.append(epic)
                }
            }
        }
        for entry in try await store.listAll(Self.macsDirectory) ?? [] where entry.kind == .file && entry.name.hasSuffix(".json") {
            if let mac = await read(MacFile.self, at: entry.path, into: &documents) {
                documents.macs.append(mac)
            }
        }
        documents.commander = await read(CommanderFile.self, at: StatePath.commander, into: &documents)
        documents.sentIntents = try await sentIntents(into: &documents)
        return documents
    }

    private func repositories() async throws(StateStoreError) -> [RepositoryFullName] {
        var found: [RepositoryFullName] = []
        for owner in try await directories(StatePath.repositories) {
            for name in try await directories("\(StatePath.repositories)/\(owner)") {
                if let repo = RepositoryFullName(rawValue: "\(owner)/\(name)") {
                    found.append(repo)
                }
            }
        }
        return found
    }

    private func readEpic(
        _ id: ULID,
        of repo: RepositoryFullName,
        into documents: inout StateDocuments
    ) async -> StateDocuments.EpicDocuments? {
        guard let epic = await read(EpicFile.self, at: StatePath.epic(repo, id), into: &documents) else {
            return nil
        }
        var epicDocuments = StateDocuments.EpicDocuments(
            epic: epic,
            questions: await read(QuestionsFile.self, at: StatePath.questions(repo, id), into: &documents),
            goal: await read(GoalFile.self, at: StatePath.goal(repo, id), into: &documents),
            readiness: await read(ReadinessFile.self, at: StatePath.readiness(repo, id), into: &documents)
        )
        guard !Self.finishedStages.contains(epic.stage) else {
            return epicDocuments
        }
        epicDocuments.jobs = await readJobs(of: epic, into: &documents)
        for job in epicDocuments.jobs {
            switch job.state {
            case .waitingHuman:
                epicDocuments.attempts[job.id] = await readAttempts(of: job, into: &documents)

            case .running where job.attempts > 0:
                // 動いている Mac と最後に動いた時刻を出す。書き換わるのは生きている印の間隔（5 分）ごとなので、ほとんどは ETag で済む
                epicDocuments.attempts[job.id] = await readAttempts(of: job, from: job.attempts, into: &documents)

            default:
                break
            }
        }
        return epicDocuments
    }

    private func readJobs(of epic: EpicFile, into documents: inout StateDocuments) async -> [JobFile] {
        let directory = StatePath.jobs(epic.repo, epic: epic.id)
        let entries: [DirectoryEntry]
        do {
            entries = try await store.listAll(directory) ?? []
        } catch {
            documents.failures.append(SourceFailure(source: directory, message: StateServiceError.message(for: error)))
            return []
        }
        var jobs: [JobFile] = []
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
            guard let job = await read(JobFile.self, at: entry.path, into: &documents) else {
                continue
            }
            // ほかの epic のジョブを出すと、やめるがその epic に当たるので、置き場所と中身が合うものだけ出す
            guard job.repo == epic.repo, job.epic == epic.id, entry.path == StatePath.job(job.repo, epic: job.epic, job: job.id) else {
                documents.failures.append(SourceFailure(source: entry.path, message: Self.misplaced))
                continue
            }
            jobs.append(job)
        }
        return jobs
    }

    static let misplaced = "置き場所と中身の合わないファイルです"

    /// ジョブの試行。人の対応を待っているジョブは、何を試したかを出すため、最後の試行だけでなくすべて読む（人に渡るジョブは少ない）
    private func readAttempts(of job: JobFile, from first: Int = 1, into documents: inout StateDocuments) async -> [AttemptFile] {
        guard job.attempts >= max(first, 1) else {
            return []
        }
        var attempts: [AttemptFile] = []
        for number in max(first, 1)...job.attempts {
            let path = StatePath.attempt(job.repo, epic: job.epic, job: job.id, number: number)
            guard let attempt = await read(AttemptFile.self, at: path, into: &documents) else {
                continue
            }
            guard attempt.job == job.id, attempt.number == number else {
                documents.failures.append(SourceFailure(source: path, message: Self.misplaced))
                continue
            }
            attempts.append(attempt)
        }
        return attempts
    }

    /// この端末の意図のうち新しいものと、その処理の記録
    private func sentIntents(into documents: inout StateDocuments) async throws(StateStoreError) -> [StateDocuments.SentIntent] {
        let sent = try await store.listAll("\(StatePath.intents)/\(device.rawValue)") ?? []
        let consumed = Set((try await store.listAll("\(StatePath.consumedDirectory)/\(device.rawValue)") ?? []).map(\.name))
        let recent = sent.filter { $0.kind == .file && $0.name.hasSuffix(".json") }.sorted { $0.name > $1.name }.prefix(sentIntentLimit)
        var intents: [StateDocuments.SentIntent] = []
        for entry in recent {
            guard let envelope = await readEnvelope(at: entry.path, into: &documents) else {
                continue
            }
            var record: ConsumedIntentFile?
            if consumed.contains(entry.name) {
                let path = StatePath.consumed(device: device, nonce: envelope.nonce)
                record = await read(ConsumedIntentFile.self, at: path, into: &documents)
            }
            intents.append(StateDocuments.SentIntent(envelope: envelope, consumed: record))
        }
        return intents
    }

    private func readEnvelope(at path: String, into documents: inout StateDocuments) async -> IntentEnvelope? {
        struct Stored: Decodable {
            var envelope: IntentEnvelope
        }
        do {
            guard let blob = try await store.read(path) else {
                return nil
            }
            return try JSONDecoder().decode(Stored.self, from: blob.data).envelope
        } catch {
            documents.failures.append(SourceFailure(source: path, message: "送った意図を読めません"))
            return nil
        }
    }

    /// 読む。読めない（知らない版・形の違い・取得の失敗）ときは `failures` に入れて nil を返す
    private func read<File: StateFile>(_ type: File.Type, at path: String, into documents: inout StateDocuments) async -> File? {
        do {
            return try await files.read(type, at: path)?.file
        } catch {
            documents.failures.append(SourceFailure(source: path, message: Self.message(for: error)))
            return nil
        }
    }

    private func directories(_ path: String) async throws(StateStoreError) -> [String] {
        try await store.listAll(path)?.filter { $0.kind == .directory }.map(\.name).sorted() ?? []
    }

    static func message(for failure: StateFileStore.Failure) -> String {
        switch failure {
        case .unreadable:
            "知らない版か、形の違うファイルです"

        case .store(let error):
            StateServiceError.message(for: error)

        default:
            "読めませんでした"
        }
    }
}
