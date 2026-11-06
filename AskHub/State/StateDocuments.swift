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
        return StateDocuments.EpicDocuments(
            epic: epic,
            questions: await read(QuestionsFile.self, at: StatePath.questions(repo, id), into: &documents),
            goal: await read(GoalFile.self, at: StatePath.goal(repo, id), into: &documents),
            readiness: await read(ReadinessFile.self, at: StatePath.readiness(repo, id), into: &documents)
        )
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
