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
        /// 人が決めていない判断。最終 PR を出した epic のものだけ読む
        var decisions: DecisionsFile?
        /// ジョブ。終わった（マージした・やめた）epic のものは読まない
        var jobs: [JobFile] = []
        /// 試行（古い順）。人の対応を待っているジョブはすべて、動いているジョブと、最後に終わった最終 PR のレビューは最後の 1 つだけ
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

/// 状態リポジトリを読む。読めないファイルは飛ばして `failures` に入れ、ほかは読み続ける。
///
/// 依存の無いもの（リポジトリ・Mac・司令塔・送った意図、epic ごと、epic の中のファイル、ジョブ、試行）は並べて読む。
/// 同時の要求の数は、`store` の側で抑える（`StateClientService` が `ConcurrencyLimitedStore` に包む）。
/// 並べても結果は変えない: 一覧・ファイル・`failures` は直列に読んでいたときと同じ順に組み立て、投げる失敗も同じ順（リポジトリ → Mac → 送った意図）で選ぶ
struct StateReader {
    let store: any StateStore
    let device: KeyID
    /// 処理の結果を出す、送った意図の件数（新しい順）
    var sentIntentLimit = 20
    /// 書いたら変わらないファイル（送った意図・処理の記録）の読んだ中身。一覧の sha が同じなら取り直さない。nil なら毎回読む
    var immutables: ImmutableFileCache?

    /// ワーカーの生きている印を置くディレクトリ（`macs/<mac>.json`）
    static let macsDirectory = "macs"
    /// ジョブを読まない epic の段階。終わった epic のジョブは人の対応を待たないので、増え続ける分を読まずに済ませる
    static let finishedStages: Set<EpicStage> = [.merged, .abandoned]

    private var files: StateFileStore { StateFileStore(store: store) }

    /// 読んだものと、その間に読めなかったもの
    struct Part<Value> {
        var value: Value
        var failures: [SourceFailure] = []
    }

    /// 1 つのリポジトリから読んだもの
    private struct RepositoryPart {
        var repository: RepositoryFile?
        var epics: [StateDocuments.EpicDocuments] = []
        var failures: [SourceFailure] = []
    }

    func read() async throws(StateStoreError) -> StateDocuments {
        async let repositories = Self.capture { () throws(StateStoreError) in try await readRepositories() }
        async let macs = Self.capture { () throws(StateStoreError) in try await readMacs() }
        async let commander = read(CommanderFile.self, at: StatePath.commander)
        async let sent = Self.capture { () throws(StateStoreError) in try await sentIntents() }
        var documents = StateDocuments()
        for part in try await repositories.get() {
            part.repository.map { documents.repositories.append($0) }
            documents.epics += part.epics
            documents.failures += part.failures
        }
        let macsPart = try await macs.get()
        documents.macs = macsPart.value
        documents.failures += macsPart.failures
        let commanderPart = await commander
        documents.commander = commanderPart.value
        documents.failures += commanderPart.failures
        let sentPart = try await sent.get()
        documents.sentIntents = sentPart.value
        documents.failures += sentPart.failures
        return documents
    }

    // MARK: リポジトリと epic

    private func readRepositories() async throws(StateStoreError) -> [RepositoryPart] {
        let owners = try await directories(StatePath.repositories)
        let names = await Self.inOrder(owners) { owner in
            await Self.capture { () throws(StateStoreError) in try await directories("\(StatePath.repositories)/\(owner)") }
        }
        var repositories: [RepositoryFullName] = []
        for (owner, listed) in zip(owners, names) {
            repositories += try listed.get().compactMap { RepositoryFullName(rawValue: "\(owner)/\($0)") }
        }
        let parts = await Self.inOrder(repositories) { repo in
            await Self.capture { () throws(StateStoreError) in try await readRepository(repo) }
        }
        var read: [RepositoryPart] = []
        for part in parts {
            read.append(try part.get())
        }
        return read
    }

    private func readRepository(_ repo: RepositoryFullName) async throws(StateStoreError) -> RepositoryPart {
        async let file = read(RepositoryFile.self, at: StatePath.repository(repo))
        async let listed = Self.capture { () throws(StateStoreError) in try await directories(StatePath.epics(repo)) }
        let fileRead = await file
        var part = RepositoryPart(repository: fileRead.value, failures: fileRead.failures)
        let ids = try await listed.get().compactMap(ULID.init(rawValue:))
        for epic in await Self.inOrder(ids, { id in await readEpic(id, of: repo) }) {
            epic.value.map { part.epics.append($0) }
            part.failures += epic.failures
        }
        return part
    }

    private func readEpic(_ id: ULID, of repo: RepositoryFullName) async -> Part<StateDocuments.EpicDocuments?> {
        // epic.json と、epic.json に依らないファイルを並べて読む。epic.json を読めなければ、ほかは使わない（失敗も出さない）
        async let epicRead = read(EpicFile.self, at: StatePath.epic(repo, id))
        async let questions = read(QuestionsFile.self, at: StatePath.questions(repo, id))
        async let goal = read(GoalFile.self, at: StatePath.goal(repo, id))
        async let readiness = read(ReadinessFile.self, at: StatePath.readiness(repo, id))
        let epicPart = await epicRead
        guard let epic = epicPart.value else {
            return Part(value: nil, failures: epicPart.failures)
        }
        let (questionsPart, goalPart, readinessPart) = await (questions, goal, readiness)
        var failures = epicPart.failures + questionsPart.failures + goalPart.failures + readinessPart.failures
        var documents = StateDocuments.EpicDocuments(
            epic: epic,
            questions: questionsPart.value,
            goal: goalPart.value,
            readiness: readinessPart.value
        )
        async let decisions = readDecisions(of: epic)
        let jobs = await readJobsAndAttempts(of: epic)
        let decisionsPart = await decisions
        documents.decisions = decisionsPart.value
        documents.jobs = jobs.value.jobs
        documents.attempts = jobs.value.attempts
        failures += decisionsPart.failures + jobs.failures
        return Part(value: documents, failures: failures)
    }

    /// 判断のカードは最終 PR の確認で出す。仮決めは実装の間も増えるが、最終 PR を出すまでは画面に出さないので読まない
    private func readDecisions(of epic: EpicFile) async -> Part<DecisionsFile?> {
        guard epic.finalPullRequest != nil, epic.stage != .abandoned else {
            return Part(value: nil)
        }
        return await read(DecisionsFile.self, at: StatePath.decisions(epic.repo, epic.id))
    }

    /// 最後に終わった最終 PR のレビュー（試行に判定を書いたもの）
    static func lastFinishedReview(in jobs: [JobFile]) -> JobFile? {
        jobs.filter { $0.kind == .reviewFinalPullRequest && $0.state == .succeeded && $0.attempts > 0 }
            .max { ($0.createdAt, $0.id.rawValue) < ($1.createdAt, $1.id.rawValue) }
    }

    // MARK: ジョブと試行

    /// ジョブと、出す試行。終わった epic のジョブは読まない
    private func readJobsAndAttempts(of epic: EpicFile) async -> Part<(jobs: [JobFile], attempts: [ULID: [AttemptFile]])> {
        guard !Self.finishedStages.contains(epic.stage) else {
            return Part(value: ([], [:]))
        }
        let jobs = await readJobs(of: epic)
        var wanted: [(job: JobFile, first: Int)] = []
        for job in jobs.value {
            switch job.state {
            case .waitingHuman:
                wanted.append((job, 1))

            case .running where job.attempts > 0:
                // 動いている Mac と最後に動いた時刻を出す。書き換わるのは生きている印の間隔（5 分）ごとなので、ほとんどは ETag で済む
                wanted.append((job, job.attempts))

            default:
                break
            }
        }
        // 最終 PR のチェックとマージの規則の材料（判定・直すこと・mergeRisks）は、最後に終わったレビューの試行にある
        if let review = Self.lastFinishedReview(in: jobs.value), !wanted.contains(where: { $0.job.id == review.id }) {
            wanted.append((review, review.attempts))
        }
        let read = await Self.inOrder(wanted) { wanted in await readAttempts(of: wanted.job, from: wanted.first) }
        var attempts: [ULID: [AttemptFile]] = [:]
        var failures = jobs.failures
        for (wanted, part) in zip(wanted, read) {
            attempts[wanted.job.id] = part.value
            failures += part.failures
        }
        return Part(value: (jobs.value, attempts), failures: failures)
    }

    private func readJobs(of epic: EpicFile) async -> Part<[JobFile]> {
        let directory = StatePath.jobs(epic.repo, epic: epic.id)
        let entries: [DirectoryEntry]
        do {
            entries = try await store.listAll(directory) ?? []
        } catch {
            return Part(value: [], failures: [SourceFailure(source: directory, message: StateServiceError.message(for: error))])
        }
        let files = entries.filter { $0.kind == .file && $0.name.hasSuffix(".json") }
        var part = Part<[JobFile]>(value: [])
        for (entry, read) in zip(files, await Self.inOrder(files, { entry in await read(JobFile.self, at: entry.path) })) {
            part.failures += read.failures
            guard let job = read.value else {
                continue
            }
            // ほかの epic のジョブを出すと、やめるがその epic に当たるので、置き場所と中身が合うものだけ出す
            guard job.repo == epic.repo, job.epic == epic.id, entry.path == StatePath.job(job.repo, epic: job.epic, job: job.id) else {
                part.failures.append(SourceFailure(source: entry.path, message: Self.misplaced))
                continue
            }
            part.value.append(job)
        }
        return part
    }

    static let misplaced = "置き場所と中身の合わないファイルです"

    /// ジョブの試行。人の対応を待っているジョブは、何を試したかを出すため、最後の試行だけでなくすべて読む（人に渡るジョブは少ない）
    private func readAttempts(of job: JobFile, from first: Int = 1) async -> Part<[AttemptFile]> {
        guard job.attempts >= max(first, 1) else {
            return Part(value: [])
        }
        let numbers = Array(max(first, 1)...job.attempts)
        let reads = await Self.inOrder(numbers) { number in
            await read(AttemptFile.self, at: StatePath.attempt(job.repo, epic: job.epic, job: job.id, number: number))
        }
        var part = Part<[AttemptFile]>(value: [])
        for (number, read) in zip(numbers, reads) {
            part.failures += read.failures
            guard let attempt = read.value else {
                continue
            }
            guard attempt.job == job.id, attempt.number == number else {
                let path = StatePath.attempt(job.repo, epic: job.epic, job: job.id, number: number)
                part.failures.append(SourceFailure(source: path, message: Self.misplaced))
                continue
            }
            part.value.append(attempt)
        }
        return part
    }

    // MARK: Mac と送った意図

    private func readMacs() async throws(StateStoreError) -> Part<[MacFile]> {
        let entries = (try await store.listAll(Self.macsDirectory) ?? []).filter { $0.kind == .file && $0.name.hasSuffix(".json") }
        var part = Part<[MacFile]>(value: [])
        for read in await Self.inOrder(entries, { entry in await read(MacFile.self, at: entry.path) }) {
            read.value.map { part.value.append($0) }
            part.failures += read.failures
        }
        return part
    }

    /// この端末の意図のうち新しいものと、その処理の記録
    private func sentIntents() async throws(StateStoreError) -> Part<[StateDocuments.SentIntent]> {
        async let sentList = Self.capture { () throws(StateStoreError) in
            try await store.listAll("\(StatePath.intents)/\(device.rawValue)")
        }
        async let consumedList = Self.capture { () throws(StateStoreError) in
            try await store.listAll("\(StatePath.consumedDirectory)/\(device.rawValue)")
        }
        let sent = try await sentList.get() ?? []
        let consumed = Dictionary((try await consumedList.get() ?? []).map { ($0.name, $0) }) { first, _ in first }
        let files = sent.filter { $0.kind == .file && $0.name.hasSuffix(".json") }
        let recent = Array(files.sorted { $0.name > $1.name }.prefix(sentIntentLimit))
        let reads = await Self.inOrder(recent) { entry in await readSent(entry, consumed: consumed[entry.name]) }
        var part = Part<[StateDocuments.SentIntent]>(value: [])
        for read in reads {
            read.value.map { part.value.append($0) }
            part.failures += read.failures
        }
        // 一覧から外れた（新しい 20 件に入らなくなった）ものは、持ち続けない
        immutables?.keep(Set(recent.map(\.path) + part.value.map { StatePath.consumed(device: device, nonce: $0.envelope.nonce) }))
        return part
    }

    /// 送った意図と、司令塔が処理していればその記録。どちらも書いたら変わらないので、一覧の sha が同じなら前に読んだものを使う
    private func readSent(_ entry: DirectoryEntry, consumed: DirectoryEntry?) async -> Part<StateDocuments.SentIntent?> {
        let envelopeRead = await readEnvelope(entry)
        guard let envelope = envelopeRead.value else {
            return Part(value: nil, failures: envelopeRead.failures)
        }
        var part = Part<StateDocuments.SentIntent?>(value: StateDocuments.SentIntent(envelope: envelope))
        if let consumed {
            let path = StatePath.consumed(device: device, nonce: envelope.nonce)
            // 一覧の名前と中身の nonce が合わないときは、sha を使い回さずに読む
            let sha = consumed.path == path ? consumed.sha : nil
            let record = await readConsumed(at: path, sha: sha)
            part.value?.consumed = record.value
            part.failures += record.failures
        }
        return part
    }

    private func readEnvelope(_ entry: DirectoryEntry) async -> Part<IntentEnvelope?> {
        struct Stored: Decodable {
            var envelope: IntentEnvelope
        }
        if let cached = immutables?.envelope(at: entry.path, sha: entry.sha) {
            return Part(value: cached)
        }
        do {
            guard let blob = try await store.read(entry.path) else {
                return Part(value: nil)
            }
            let envelope = try JSONDecoder().decode(Stored.self, from: blob.data).envelope
            immutables?.store(envelope, at: entry.path, sha: blob.sha)
            return Part(value: envelope)
        } catch {
            return Part(value: nil, failures: [SourceFailure(source: entry.path, message: "送った意図を読めません")])
        }
    }

    private func readConsumed(at path: String, sha: String?) async -> Part<ConsumedIntentFile?> {
        if let sha, let cached = immutables?.consumed(at: path, sha: sha) {
            return Part(value: cached)
        }
        do {
            guard let loaded = try await files.read(ConsumedIntentFile.self, at: path) else {
                return Part(value: nil)
            }
            immutables?.store(loaded.file, at: path, sha: loaded.sha)
            return Part(value: loaded.file)
        } catch {
            return Part(value: nil, failures: [SourceFailure(source: path, message: Self.message(for: error))])
        }
    }

    // MARK: 読み方

    /// 読む。読めない（知らない版・形の違い・取得の失敗）ときは、失敗を添えて nil を返す
    private func read<File: StateFile>(_ type: File.Type, at path: String) async -> Part<File?> {
        do {
            return Part(value: try await files.read(type, at: path)?.file)
        } catch {
            return Part(value: nil, failures: [SourceFailure(source: path, message: Self.message(for: error))])
        }
    }

    private func directories(_ path: String) async throws(StateStoreError) -> [String] {
        try await store.listAll(path)?.filter { $0.kind == .directory }.map(\.name).sorted() ?? []
    }

    /// `items` を並べて処理し、`items` の順に返す
    static func inOrder<Item: Sendable, Value: Sendable>(
        _ items: [Item],
        _ transform: @escaping @Sendable (Item) async -> Value
    ) async -> [Value] {
        await withTaskGroup(of: (Int, Value).self) { group in
            for (index, item) in items.enumerated() {
                group.addTask { (index, await transform(item)) }
            }
            var values: [Int: Value] = [:]
            for await (index, value) in group {
                values[index] = value
            }
            return items.indices.compactMap { values[$0] }
        }
    }

    /// 投げるかもしれない読み込みを、並べて待てる形（`Result`）にする
    static func capture<Value>(_ body: () async throws(StateStoreError) -> Value) async -> Result<Value, StateStoreError> {
        do {
            return .success(try await body())
        } catch {
            return .failure(error)
        }
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

/// 書いたら変わらないファイル（送った意図・司令塔の処理の記録）の、読んだ中身。
/// 30 秒ごとの取り直しのたびに読み直さないよう、一覧の sha が同じなら取り直さずに使う（変わらないファイルでも、sha が変われば読み直す）
final class ImmutableFileCache {
    private var envelopes: [String: (sha: String, envelope: IntentEnvelope)] = [:]
    private var records: [String: (sha: String, record: ConsumedIntentFile)] = [:]

    func envelope(at path: String, sha: String) -> IntentEnvelope? {
        envelopes[path].flatMap { $0.sha == sha ? $0.envelope : nil }
    }

    func consumed(at path: String, sha: String) -> ConsumedIntentFile? {
        records[path].flatMap { $0.sha == sha ? $0.record : nil }
    }

    func store(_ envelope: IntentEnvelope, at path: String, sha: String) {
        envelopes[path] = (sha, envelope)
    }

    func store(_ record: ConsumedIntentFile, at path: String, sha: String) {
        records[path] = (sha, record)
    }

    /// `paths` のほかを捨てる
    func keep(_ paths: Set<String>) {
        envelopes = envelopes.filter { paths.contains($0.key) }
        records = records.filter { paths.contains($0.key) }
    }
}
