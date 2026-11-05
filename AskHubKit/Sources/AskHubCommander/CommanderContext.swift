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
        JobFile(
            id: .derived(from: origin.nonce, seed: "\(origin.keyId)/\(kind.rawValue)/\(seed)"),
            kind: kind,
            repo: epic.repo,
            epic: epic.id,
            assignedMac: mac,
            needs: .init(claude: true, build: false),
            state: .queued,
            input: input,
            origin: origin,
            createdAt: timestamp,
            updatedAt: timestamp
        )
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

    /// epic のジョブ（読めないファイルは飛ばす）
    func jobs(_ repo: RepositoryFullName, epic: ULID) async throws(CommanderError) -> [JobFile] {
        let entries: [DirectoryEntry]
        do {
            entries = try await store.list(StatePath.jobs(repo, epic: epic)) ?? []
        } catch {
            throw .store(error)
        }
        var jobs: [JobFile] = []
        for entry in entries where entry.kind == .file && entry.name.hasSuffix(".json") {
            do {
                if let loaded = try await files.read(JobFile.self, at: entry.path) { jobs.append(loaded.file) }
            } catch .unreadable {
                continue
            } catch {
                throw .files(error)
            }
        }
        return jobs
    }

    /// 終わっていないジョブのうち、`matches` に合うものを取り消す
    func cancelJobs(_ repo: RepositoryFullName, epic: ULID, where matches: (JobFile) -> Bool) async throws(CommanderError) {
        let open: Set<JobState> = [.queued, .assigned, .running, .waitingHuman, .paused]
        for job in try await jobs(repo, epic: epic) where open.contains(job.state) && matches(job) {
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

extension JSONValue {
    /// `Encodable` の値を JSON の値にする（ジョブの入力に入れる）
    static func encoding(_ value: some Encodable) -> JSONValue? {
        (try? JSONEncoder().encode(value)).flatMap { try? JSONValue(parsing: $0) }
    }
}
