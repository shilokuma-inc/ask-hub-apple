import AskHubJobs
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
    /// 人の意図の処理と、Claude のジョブの結果を書く処理を 1 つずつにする（コピーしても同じものを使う）
    public let lock: CommanderLock
    /// 書き込みの予算・GitHub の上限に当たった Claude のジョブの結果を、待って書き直す長さの合計の上限
    public var writeWaitLimit = JobTiming().writeWaitLimit

    public init(
        store: any StateStore,
        mac: MacName,
        lock: CommanderLock = CommanderLock(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.store = store
        files = StateFileStore(store: store)
        self.mac = mac
        self.lock = lock
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
    /// 人の意図の署名を確かめる公開鍵の一覧を、信用できる形で作れない（記録の巻き戻し・Keychain の問題など）。人の意図を処理しない
    case untrustedKeys(String)
}

// MARK: - 結果を書く

extension CommanderContext {
    /// Claude のジョブの結果を、読み直してから書き終えるまで排他の中で行う。書き込みの予算・GitHub の上限に当たったら、
    /// 排他の外で待ってから読み直して書き直す（呼んだ Claude の結果を捨てない。待つ間も人の意図の処理は進める）。
    /// `body` は、途中まで書いて止まっても、やり直せば同じ結果になる形にする
    func writingResult<T: Sendable>(_ body: () async throws(CommanderError) -> T) async throws(CommanderError) -> T {
        var waited = Duration.zero
        while true {
            do {
                return try await lock.withLock(body)
            } catch {
                guard let wait = error.retryAfter, waited + wait <= writeWaitLimit else { throw error }
                do {
                    try await files.sleeper.sleep(for: wait)
                } catch {
                    throw .store(.cancelled)
                }
                waited += wait
            }
        }
    }
}

extension CommanderError {
    /// 待てば書ける失敗（書き込みの予算を使い切った・GitHub の上限）の、次に試せるまでの時間
    var retryAfter: Duration? {
        switch self {
        case let .store(error), let .files(.store(error)): error.retryAfter
        default: nil
        }
    }
}

// MARK: - ジョブ

extension CommanderContext {
    /// 常時オンの Mac で Claude を呼ぶジョブ。id は元になった人の意図（鍵と番号。処理した記録と同じ組）と `seed` から決めるので、
    /// やり直しても同じジョブを 2 つ作らない
    func claudeJob(
        _ kind: JobKind,
        for epic: EpicFile,
        origin: IntentReference,
        seed: String,
        input: [String: JSONValue],
        after parents: [ULID] = []
    ) -> JobFile {
        let spec = JobSpec(kind: kind, mac: mac, needs: .init(claude: true, build: false), input: input, dependsOn: parents)
        return job(spec, for: epic, origin: origin, seed: seed)
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
            dependsOn: spec.dependsOn,
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
            // ジョブは消さずに増えるので、1,000 件で切れる `list` ではなく `listAll` で直下をすべて読む
            entries = try await store.listAll(StatePath.jobs(repo, epic: epic)) ?? []
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

// MARK: - epic と人の意図を読む

extension CommanderContext {
    /// `repos/<owner>/<repo>/` の一覧
    func repositories() async throws(CommanderError) -> [RepositoryFullName] {
        var repositories: [RepositoryFullName] = []
        for owner in try await directories(in: StatePath.repositories) {
            for name in try await directories(in: "\(StatePath.repositories)/\(owner)") {
                if let repo = RepositoryFullName(rawValue: "\(owner)/\(name)") { repositories.append(repo) }
            }
        }
        return repositories
    }

    /// リポジトリの epic のうち、`matches` に合うもの。読めない（知らない版など）epic は飛ばす
    func epics(of repo: RepositoryFullName, where matches: (EpicFile) -> Bool) async throws(CommanderError) -> [EpicFile] {
        var epics: [EpicFile] = []
        for name in try await directories(in: StatePath.epics(repo)) {
            guard let id = ULID(rawValue: name), let epic = try await readable(EpicFile.self, at: StatePath.epic(repo, id)),
                  matches(epic) else { continue }
            epics.append(epic)
        }
        return epics
    }

    /// ディレクトリの直下のディレクトリの名前
    func directories(in directory: String) async throws(CommanderError) -> [String] {
        do {
            return try await store.listAll(directory)?.filter { $0.kind == .directory }.map(\.name) ?? []
        } catch {
            throw .store(error)
        }
    }

    /// 読めない（知らない版など）ファイルは nil にして飛ばす
    func readable<File: StateFile>(_ type: File.Type, at path: String) async throws(CommanderError) -> File? {
        do {
            return try await files.read(File.self, at: path)?.file
        } catch .unreadable {
            return nil
        } catch {
            throw .files(error)
        }
    }

    /// 受け付けた人の意図を読み直す（署名を確かめてから使う。有効期間は見ない。受け付けたときに確かめている）。
    /// 無い・署名が合わない・置き場所と封筒が食い違うときは nil
    func envelope(of origin: IntentReference?, verifier: IntentVerifier) async throws(CommanderError) -> IntentEnvelope? {
        guard let origin else { return nil }
        var verifier = verifier
        verifier.maximumAge = .greatestFiniteMagnitude
        let blob: StoredBlob?
        do {
            blob = try await store.read(StatePath.intent(device: origin.keyId, nonce: origin.nonce))
        } catch {
            throw .store(error)
        }
        guard let data = blob?.data, let value = try? JSONValue(parsing: data),
              let envelope = try? verifier.verify(stored: value, now: now()),
              envelope.keyId == origin.keyId, envelope.nonce == origin.nonce else {
            return nil
        }
        return envelope
    }
}

/// 作るジョブの中身（種類・割り当てる Mac・使うもの・入力）
struct JobSpec {
    var kind: JobKind
    var mac: MacName
    var needs: JobFile.Needs
    var input: [String: JSONValue] = [:]
    /// 先に成功している必要のあるジョブ。Claude のジョブの結果から作るジョブは、そのジョブが結果を書き終えてから動かす
    var dependsOn: [ULID] = []
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
