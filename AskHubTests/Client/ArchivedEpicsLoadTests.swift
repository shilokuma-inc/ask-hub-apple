@testable import AskHub
import AskHubKeychain
import AskHubProtocol
import AskHubStateStore
import Foundation
import Testing

/// 終わった epic を `archive/` に畳むと、アプリの読み込みが軽くなる（読むファイルが減り、`archive/` は読まない）
@MainActor
struct ArchivedEpicsLoadTests {
    static let repo = RepositoryFullName(rawValue: "example/sample-ios")!
    static let running = "01JCEP1C000000000000000001"
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// 終わった epic の id（2026-11 にマージ・やめたもの）
    static let finished = (2...11).map { "01JCEP1C0000000000000000\(String(format: "%02d", $0))" }

    static func epic(_ id: String, stage: String) -> String {
        """
        {"v":1,"id":"\(id)","repo":"\(repo)","title":"epic \(id.suffix(2))","summary":"要約","discussion":5,"stage":"\(stage)",
         "mac":"mac-mini","branch":"askhub/\(id)","finalPullRequest":null,"goalVersion":1,"origin":null,
         "createdAt":"2026-11-01T00:00:00Z","updatedAt":"2026-11-10T00:00:00Z"}
        """
    }

    /// 動いている epic 1 本と、終わった epic 10 本（それぞれゴール・質問・ジョブ・試行を持つ）
    static func files() -> [String: Data] {
        var files = [
            "repos/\(repo)/repo.json": """
            {"v":1,"repo":"\(repo)","platform":"apple","maxConcurrentEpics":1,"appKit":null,
             "protection":{"appliedAt":null},"addedAt":"2026-11-01T00:00:00Z"}
            """,
            "repos/\(repo)/epics/\(running)/epic.json": epic(running, stage: "running")
        ]
        for (offset, id) in finished.enumerated() {
            let base = "repos/\(repo)/epics/\(id)"
            let job = "01JCJ0B00000000000000000\(String(format: "%02d", offset + 1))"
            files["\(base)/epic.json"] = epic(id, stage: offset.isMultiple(of: 2) ? "merged" : "abandoned")
            files["\(base)/goal.json"] = """
            {"v":1,"version":1,"summary":"要約","decided":[],"outOfScope":[],"doneWhen":["終わる"],
             "tasks":[{"id":"t1","title":"作る","dependsOn":[],"state":"done"}],"humanTasks":[]}
            """
            files["\(base)/questions.json"] = #"{"v":1,"questions":[]}"#
            files["\(base)/jobs/\(job).json"] = """
            {"v":1,"id":"\(job)","kind":"cleanUp","repo":"\(repo)","epic":"\(id)","task":null,"assignedMac":"mac-mini",
             "needs":{"claude":false,"build":false},"dependsOn":[],"state":"succeeded","attempts":1,"nextRunAt":null,"input":{},
             "origin":null,"createdAt":"2026-11-10T00:00:00Z","updatedAt":"2026-11-10T00:00:00Z"}
            """
        }
        return files.mapValues { Data($0.utf8) }
    }

    /// 新しい窓口（前に読んだものを持たない）で 1 回読み、読んだ回数と epic を返す
    func load(_ store: InMemoryStateStore) async throws -> (reads: Int, epics: [Epic.ID]) {
        let counter = ReadCounter()
        let key = try DeviceSigningKey.loadOrCreate(in: InMemorySecretStore(), useSecureEnclave: false)
        let now = now
        let snapshot = try await StateClientService(store: CountingStore(base: store, counter: counter), key: key) { now }.fetchSnapshot()
        #expect(snapshot.sourceFailures.isEmpty)
        return (await counter.reads, snapshot.epics.map(\.id).sorted())
    }

    @Test
    func archivingFinishedEpicsLightensLoading() async throws {
        let store = InMemoryStateStore(files: Self.files())
        let before = try await load(store)
        #expect(before.epics == ([Self.running] + Self.finished).sorted())

        // 司令塔（`FinishedEpicArchive`）と同じく、終わった epic のフォルダを archive/ にまとめて移す
        var moves: [StateMove] = []
        for id in Self.finished {
            let folder = StatePath.epicDirectory(Self.repo, try #require(ULID(rawValue: id)))
            moves.append(StateMove(from: folder, to: StatePath.archived(folder)))
        }
        try await store.move(moves, message: "archive")
        let after = try await load(store)
        #expect(after.epics == [Self.running])
        // 終わった epic 1 本ぶん（epic・ゴール・質問・ジョブの一覧など）を読まなくなる（10 本で 59 回から 14 回）
        #expect(after.reads < before.reads)

        // archive/ は読まない（はじめから終わった epic が無いときと同じ回数）
        let onlyRunning = InMemoryStateStore(files: Self.files().filter { path, _ in !Self.finished.contains { path.contains($0) } })
        #expect(try await load(onlyRunning).reads == after.reads)
    }
}

/// 読んだ回数（一覧とファイル）を数える
private actor ReadCounter {
    private(set) var reads = 0

    func add() {
        reads += 1
    }
}

/// 読み取りを数える置き場所。写しから読んだ分も同じ数に足す
private struct CountingStore: StateStore {
    let base: any StateStore
    let counter: ReadCounter

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        await counter.add()
        return try await base.read(path)
    }

    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        await counter.add()
        return try await base.list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        try await base.write(path, data: data, replacing: sha, message: message)
    }

    func snapshot() async throws(StateStoreError) -> any StateStore {
        Self(base: try await base.snapshot(), counter: counter)
    }
}
