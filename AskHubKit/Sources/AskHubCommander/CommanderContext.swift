import AskHubProtocol
import AskHubStateStore
import Foundation

/// 司令塔の処理が使うもの（状態リポジトリ・自分の Mac・時刻）
public struct CommanderContext: Sendable {
    public var files: StateFileStore
    public var store: any StateStore
    /// 司令塔が動く常時オンの Mac。質問づくり・説明・見直し・着手前の確認のジョブは、この Mac に割り当てる
    public var mac: MacName
    public var now: @Sendable () -> Date

    public init(store: any StateStore, mac: MacName, now: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        files = StateFileStore(store: store)
        self.mac = mac
        self.now = now
    }

    public var timestamp: Timestamp { Timestamp(now()) }
}

/// 司令塔の処理の失敗。状態リポジトリに書けなかったなど、あとでやり直せば済むもの
public enum CommanderError: Error, Equatable, Sendable {
    case store(StateStoreError)
    case files(StateFileStore.Failure)
    /// 読んだファイルが、処理の途中で別の書き込みで変わった。次の周でやり直す
    case changedWhileProcessing(String)
}

// MARK: - ジョブ

extension CommanderContext {
    /// 常時オンの Mac で Claude を呼ぶジョブ。id は元になった人の意図（鍵と番号。処理した記録と同じ組）と `seed` から決めるので、
    /// やり直しても同じジョブを 2 つ作らない
    func claudeJob(_ kind: JobKind, for epic: EpicFile, origin: IntentReference, seed: String, input: [String: JSONValue]) -> JobFile {
        job(JobSpec(kind: kind, mac: mac, needs: .init(claude: true, build: false), input: input), for: epic, origin: origin, seed: seed)
    }

    /// `spec.mac` に割り当てるジョブ。担当の Mac を決めて作るので、最初から `assigned` にする（ワーカーは自分宛ての `assigned` を引き受ける）。
    /// id は `claudeJob` と同じく、元になった人の意図と `seed` から決める
    func job(_ spec: JobSpec, for epic: EpicFile, origin: IntentReference, seed: String) -> JobFile {
        JobFile(
            id: .derived(from: origin.nonce, seed: "\(origin.keyId)/\(spec.kind.rawValue)/\(seed)"),
            kind: spec.kind,
            repo: epic.repo,
            epic: epic.id,
            assignedMac: spec.mac,
            needs: spec.needs,
            state: .assigned,
            input: spec.input,
            origin: origin,
            createdAt: timestamp,
            updatedAt: timestamp
        )
    }

    /// ファイルを読む。読めない（知らない版など）ファイルはそのまま失敗として返す
    func read<File: StateFile>(_ type: File.Type, at path: String) async throws(CommanderError) -> File? {
        do {
            return try await files.read(File.self, at: path)?.file
        } catch {
            throw .files(error)
        }
    }

    /// 終わっていないジョブのうち、`matches` に合うものがあるか。読めないジョブがあれば、確かめられないので `nil`
    func hasOpenJob(_ repo: RepositoryFullName, epic: ULID, where matches: (JobFile) -> Bool) async throws(CommanderError) -> Bool? {
        let list = try await jobList(repo, epic: epic)
        if list.jobs.contains(where: { JobFile.openStates.contains($0.state) && matches($0) }) { return true }
        return list.unreadable.isEmpty ? false : nil
    }

    /// ジョブを作る。すでにあれば（やり直したとき）そのまま
    func create(_ job: JobFile) async throws(CommanderError) {
        do {
            try await files.create(job, at: StatePath.job(job.repo, epic: job.epic, job: job.id), message: "ジョブ \(job.kind.rawValue) を作る")
        } catch .alreadyExists {
            return
        } catch {
            throw .files(error)
        }
    }

    /// epic のジョブと、読めない（知らない版など）ジョブのパス
    struct JobList {
        var jobs: [JobFile] = []
        var unreadable: [String] = []
    }

    func jobList(_ repo: RepositoryFullName, epic: ULID) async throws(CommanderError) -> JobList {
        let entries: [DirectoryEntry]
        do {
            entries = try await store.list(StatePath.jobs(repo, epic: epic)) ?? []
        } catch {
            throw .store(error)
        }
        var list = JobList()
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
            do {
                if let loaded = try await files.read(JobFile.self, at: entry.path) { list.jobs.append(loaded.file) }
            } catch .unreadable {
                list.unreadable.append(entry.path)
            } catch {
                throw .files(error)
            }
        }
        return list
    }

    /// 終わっていないジョブのうち、`matches` に合うものを取り消す
    func cancelJobs(_ repo: RepositoryFullName, epic: ULID, where matches: (JobFile) -> Bool) async throws(CommanderError) {
        let open = JobFile.openStates
        // 読めないジョブは、中身が分からないので取り消さない（新しい司令塔が扱う）
        for job in try await jobList(repo, epic: epic).jobs where open.contains(job.state) && matches(job) {
            let now = timestamp
            do {
                let path = StatePath.job(repo, epic: epic, job: job.id)
                try await files.update(JobFile.self, at: path, message: "ジョブ \(job.kind.rawValue) を取り消す") {
                    guard open.contains($0.state) else { return false }
                    $0.state = .canceled
                    $0.updatedAt = now
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
    }
}

/// 作るジョブの中身（種類・割り当てる Mac・使うもの・入力）
struct JobSpec {
    var kind: JobKind
    var mac: MacName
    var needs: JobFile.Needs
    var input: [String: JSONValue] = [:]
}

extension JobFile {
    /// 終わっていない（取り消せる）ジョブの状態
    static let openStates: Set<JobState> = [.queued, .assigned, .running, .waitingHuman, .paused]
}

extension JSONValue {
    /// `Encodable` の値を JSON の値にする（ジョブの入力に入れる）
    static func encoding(_ value: some Encodable) -> JSONValue? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONValue(parsing: $0) }
    }
}
