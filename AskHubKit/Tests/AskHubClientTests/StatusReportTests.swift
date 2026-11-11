@testable import AskHubClient
import AskHubProtocol
import AskHubStateStore
import CryptoKit
import Foundation
import os
import Testing

/// 非常口の `askhub status` の中身（`StatusReport`）
struct StatusReportTests {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let epic = ULID(rawValue: "01JCJ0A0000000000000000001")!
    static let waiting = ULID(rawValue: "01JCJ0B0000000000000000001")!
    static let succeeded = ULID(rawValue: "01JCJ0B0000000000000000002")!
    static let device = KeyID(rawValue: String(repeating: "k", count: 43))!
    static let mac = MacName(rawValue: "mac-mini")!
    static let time = Timestamp(Date(timeIntervalSince1970: 1_793_757_600))

    /// epic が 1 つ、人の対応待ちのジョブと終わったジョブが 1 つずつ、送った意図の結果が 1 つ。質問・着手前の確認・ゴールは無い
    static func files() throws -> [String: Data] {
        let epicFile = EpicFile(id: epic, repo: repo, title: "ランキング", stage: .running, mac: mac, createdAt: time, updatedAt: time)
        let failure = AttemptFailure(failureClass: .buildFailed, message: "ビルドが通らない")
        let attempt = AttemptFile(
            job: waiting, number: 1, mac: mac, startedAt: time, heartbeatAt: time, endedAt: time, outcome: .failed, failure: failure
        )
        let consumed = ConsumedIntentFile(kind: "answer", consumedAt: time, result: .accepted)
        return [
            StatePath.epic(repo, epic): try StateFileCoder.encode(epicFile),
            StatePath.job(repo, epic: epic, job: waiting): try StateFileCoder.encode(job(waiting, state: .waitingHuman)),
            StatePath.job(repo, epic: epic, job: succeeded): try StateFileCoder.encode(job(succeeded, state: .succeeded)),
            StatePath.attempt(repo, epic: epic, job: waiting, number: 1): try StateFileCoder.encode(attempt),
            "\(StatePath.consumedDirectory)/\(device.rawValue)/01JCJ0C0000000000000000001.json": try StateFileCoder.encode(consumed)
        ]
    }

    static func job(_ id: ULID, state: JobState) -> JobFile {
        JobFile(
            id: id,
            kind: .implementTask,
            repo: repo,
            epic: epic,
            needs: .init(claude: true, build: true),
            state: state,
            attempts: 1,
            createdAt: time,
            updatedAt: time
        )
    }

    @Test func rendersEpicsWaitingJobsAndConsumedIntentsFromSnapshot() async throws {
        let store = SnapshotOnlyStore(InMemoryStateStore(files: try Self.files()))
        let target = "--repo \(Self.repo.rawValue) --epic \(Self.epic.rawValue) --job \(Self.waiting.rawValue) --attempt 1"
        let expected = """
            ■ shilokuma-inc/askhub-sandbox
              epic \(Self.epic.rawValue)「ランキング」 段階: running Mac: mac-mini
                人の対応待ちのジョブ implementTask \(Self.waiting.rawValue)（試行 1）
                  失敗: buildFailed ビルドが通らない
                  やり直す: askhub retry \(target)
                  やめる: askhub give-up \(target)
            ■ 送った意図の処理の結果
              01JCJ0C0000000000000000001 answer: accepted
            """
        #expect(try await StatusReport.render(store, repository: Self.repo, device: Self.device) == expected)
        // リポジトリを指さなければ、状態リポジトリにあるリポジトリをすべて出す
        #expect(try await StatusReport.render(store, repository: nil, device: Self.device) == expected)
        #expect(await store.snapshots == 2)
    }

    @Test func rereadingUnchangedStateSendsOnlyRootListing() async throws {
        let github = FakeGitHubState(files: try Self.files())
        let store = GitHubContentsStore(repository: FakeGitHubState.repository, transport: github, budget: nil) { "test-token-not-real" }
        let first = try await StatusReport.render(store, repository: Self.repo, device: Self.device)
        // 無いファイル（質問・着手前の確認・ゴール）は tree で分かるので、取りに行かない（GitHub は 404 も上限に数える）
        #expect(!github.statuses.contains(404))
        #expect(github.statuses.count == 16)

        // 変わっていなければ、直下の一覧の 304（上限に数えられない）だけ
        #expect(try await StatusReport.render(store, repository: Self.repo, device: Self.device) == first)
        #expect(github.statuses.dropFirst(16) == [304])

        // 1 つのジョブが変われば、そこまでの tree（repos・owner・repo・epics・epic・jobs）と、そのジョブの blob と、直下の一覧だけ
        let running = try StateFileCoder.encode(Self.job(Self.waiting, state: .running))
        github.put(StatePath.job(Self.repo, epic: Self.epic, job: Self.waiting), data: running)
        let changed = try await StatusReport.render(store, repository: Self.repo, device: Self.device)
        #expect(!changed.contains("人の対応待ちのジョブ"))
        #expect(github.statuses.dropFirst(17) == [200, 200, 200, 200, 200, 200, 200, 200])
    }
}

/// 写しからしか読ませない。写しを作らずに読むと失敗する
actor SnapshotOnlyStore: StateStore {
    private let inner: InMemoryStateStore
    private(set) var snapshots = 0

    init(_ inner: InMemoryStateStore) {
        self.inner = inner
    }

    func read(_ path: String) throws(StateStoreError) -> StoredBlob? {
        throw .unexpected(status: 0, message: "写しを作らずに読んだ")
    }

    func list(_ directory: String) throws(StateStoreError) -> [DirectoryEntry]? {
        throw .unexpected(status: 0, message: "写しを作らずに並べた")
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) throws(StateStoreError) -> String {
        throw .unexpected(status: 0, message: "書かない")
    }

    func snapshot() async throws(StateStoreError) -> any StateStore {
        snapshots += 1
        return try await inner.snapshot()
    }
}

/// 状態リポジトリのファイルから、GitHub の直下の一覧（Contents API。ETag つき）・tree・blob に答える。応答の状態を古い順に残す
final class FakeGitHubState: HTTPTransport {
    static let repository = RepositoryFullName(rawValue: "shilokuma-inc/askhub-state")!

    private struct State {
        var files: [String: Data]
        var statuses: [Int] = []
    }

    private let state: OSAllocatedUnfairLock<State>

    init(files: [String: Data]) {
        state = OSAllocatedUnfairLock(initialState: State(files: files))
    }

    var statuses: [Int] {
        state.withLock { $0.statuses }
    }

    func put(_ path: String, data: Data) {
        state.withLock { $0.files[path] = data }
    }

    private struct Reply {
        var status: Int
        var body = Data()
        var headers: [String: String] = [:]

        static func json(_ object: Any, headers: [String: String] = [:]) -> Self {
            Self(status: 200, body: (try? JSONSerialization.data(withJSONObject: object)) ?? Data(), headers: headers)
        }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let reply = state.withLock { state in
            let reply = Self.reply(to: request, objects: GitObjects(files: state.files))
            state.statuses.append(reply.status)
            return reply
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers) else {
            throw URLError(.badServerResponse)
        }
        return (reply.body, response)
    }

    private static func reply(to request: URLRequest, objects: GitObjects) -> Reply {
        let prefix = "/repos/\(repository.rawValue)/"
        guard let path = request.url?.path, path.hasPrefix(prefix) else { return Reply(status: 404) }
        let rest = path.dropFirst(prefix.count)
        if rest == "contents" || rest == "contents/" {
            let etag = "\"\(objects.root)\""
            if request.value(forHTTPHeaderField: "If-None-Match") == etag { return Reply(status: 304) }
            let listing = (objects.trees[objects.root] ?? []).map { entry in
                ["type": entry.isTree ? "dir" : "file", "name": entry.name, "path": entry.name, "sha": entry.sha]
            }
            return .json(listing, headers: ["ETag": etag])
        }
        if rest.hasPrefix("git/trees/"), let tree = objects.trees[String(rest.dropFirst("git/trees/".count))] {
            let items = tree.map { ["path": $0.name, "type": $0.isTree ? "tree" : "blob", "sha": $0.sha] }
            return .json(["truncated": false, "tree": items] as [String: Any])
        }
        if rest.hasPrefix("git/blobs/"), let blob = objects.blobs[String(rest.dropFirst("git/blobs/".count))] {
            return Reply(status: 200, body: blob)
        }
        return Reply(status: 404)
    }
}

/// ファイルから作った Git の tree と blob。blob の sha は Git と同じ求め方、tree の sha は中身から作るので、中身が同じなら同じになる
private struct GitObjects {
    struct Entry {
        var name: String
        var isTree: Bool
        var sha: String
    }

    private(set) var trees: [String: [Entry]] = [:]
    private(set) var blobs: [String: Data] = [:]
    private(set) var root = ""

    init(files: [String: Data]) {
        root = add("", files: files)
    }

    /// `prefix` の下の tree を作り、その sha を返す
    private mutating func add(_ prefix: String, files: [String: Data]) -> String {
        let names = Set(files.keys.compactMap { path in
            path.hasPrefix(prefix) ? path.dropFirst(prefix.count).split(separator: "/").first.map(String.init) : nil
        })
        var entries: [Entry] = []
        for name in names.sorted() {
            if let data = files[prefix + name] {
                let sha = Self.sha1(Data("blob \(data.count)\0".utf8) + data)
                blobs[sha] = data
                entries.append(Entry(name: name, isTree: false, sha: sha))
            } else {
                entries.append(Entry(name: name, isTree: true, sha: add(prefix + name + "/", files: files)))
            }
        }
        let sha = Self.sha1(Data(entries.map { "\($0.isTree ? "tree" : "blob") \($0.sha) \($0.name)\n" }.joined().utf8))
        trees[sha] = entries
        return sha
    }

    private static func sha1(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
