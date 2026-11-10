import AskHubProtocol
@testable import AskHubStateStore
import Foundation
import Testing

/// 読むだけの写し（`GitHubContentsStore.snapshot()`）
struct GitHubStateSnapshotTests {
    private static let repository = RepositoryFullName(rawValue: "shilokuma-inc/askhub-state")!
    private static let mac = Data(#"{"v":1,"mac":"mac-mini"}"#.utf8)
    private static let version = Data(#"{"v":1}"#.utf8)

    private func store(_ transport: StubTransport, branch: String? = nil) -> GitHubContentsStore {
        GitHubContentsStore(repository: Self.repository, branch: branch, transport: transport, budget: nil) { "test-token-not-real" }
    }

    /// 直下の一覧（Contents API）。`macs` は tree の sha が `macs`
    private static func root(macs: String, etag: String) -> StubTransport.Reply {
        let listing = """
        [{"type":"dir","name":"macs","path":"macs","sha":"\(macs)"},\
        {"type":"file","name":"version.json","path":"version.json","sha":"\(GitBlobSHA.of(version))"}]
        """
        return .json(200, listing, headers: ["ETag": etag])
    }

    /// Git Trees API の tree の 1 つ
    private struct TreeEntry {
        var path: String
        var type = "blob"
        var sha: String
    }

    private static func tree(_ sha: String, _ entries: [TreeEntry]) -> StubTransport.Reply {
        let items = entries.map { #"{"path":"\#($0.path)","type":"\#($0.type)","sha":"\#($0.sha)"}"# }
        return .json(200, #"{"sha":"\#(sha)","truncated":false,"tree":[\#(items.joined(separator: ","))]}"#)
    }

    private static func blob(_ data: Data) -> StubTransport.Reply {
        .init(status: 200, headers: [:], body: data)
    }

    @Test func readsThroughTreesAndBlobsAndReusesThemInNextSnapshot() async throws {
        let macSHA = GitBlobSHA.of(Self.mac)
        let transport = StubTransport([
            Self.root(macs: "aaa111", etag: "\"r1\""),
            Self.tree("aaa111", [.init(path: "mac-mini.json", sha: macSHA)]),
            Self.blob(Self.mac),
            .init(status: 304)
        ])
        let store = store(transport, branch: "main")
        let first = try await store.snapshot()
        #expect(try await first.read("macs/mac-mini.json") == StoredBlob(data: Self.mac, sha: macSHA))
        let urls = transport.requests.compactMap(\.url?.absoluteString)
        #expect(urls.first?.hasSuffix("/contents?ref=main") == true || urls.first?.hasSuffix("/contents/?ref=main") == true)
        #expect(urls.dropFirst().first?.hasSuffix("/repos/shilokuma-inc/askhub-state/git/trees/aaa111") == true)
        #expect(urls.last?.hasSuffix("/repos/shilokuma-inc/askhub-state/git/blobs/\(macSHA)") == true)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
        // 次の写しは、直下の一覧が 304 なら、tree も blob も取りに行かない
        let second = try await store.snapshot()
        #expect(try await second.read("macs/mac-mini.json") == StoredBlob(data: Self.mac, sha: macSHA))
        #expect(transport.requests.count == 4)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"r1\"")
    }

    @Test func fetchesOnlyChangedTreesAndBlobs() async throws {
        let other = Data(#"{"v":1,"mac":"mbp"}"#.utf8)
        let changed = Data(#"{"v":1,"mac":"mbp","load":1}"#.utf8)
        let transport = StubTransport([
            Self.root(macs: "aaa111", etag: "\"r1\""),
            Self.tree("aaa111", [
                .init(path: "mac-mini.json", sha: GitBlobSHA.of(Self.mac)), .init(path: "mbp.json", sha: GitBlobSHA.of(other))
            ]),
            Self.blob(Self.mac),
            Self.blob(other),
            Self.root(macs: "bbb222", etag: "\"r2\""),
            Self.tree("bbb222", [
                .init(path: "mac-mini.json", sha: GitBlobSHA.of(Self.mac)), .init(path: "mbp.json", sha: GitBlobSHA.of(changed))
            ]),
            Self.blob(changed)
        ])
        let store = store(transport)
        let first = try await store.snapshot()
        _ = try await first.read("macs/mac-mini.json")
        #expect(try await first.read("macs/mbp.json")?.data == other)
        // 書き換わった後の写しでは、変わった tree と blob だけを取りに行く
        let second = try await store.snapshot()
        #expect(try await second.read("macs/mac-mini.json")?.data == Self.mac)
        #expect(try await second.read("macs/mbp.json")?.data == changed)
        #expect(transport.requests.count == 7)
        // 前の写しは、作ったときの中身のまま（tree も blob も持っているので、取りに行かない）
        #expect(try await first.read("macs/mbp.json")?.data == other)
        #expect(transport.requests.count == 7)
    }

    @Test func refusesBlobThatDoesNotMatchSha() async throws {
        let macSHA = GitBlobSHA.of(Self.mac)
        let transport = StubTransport([
            Self.root(macs: "aaa111", etag: "\"r1\""),
            Self.tree("aaa111", [.init(path: "mac-mini.json", sha: macSHA)]),
            Self.blob(Data("other".utf8)),
            Self.blob(Self.mac)
        ])
        let snapshot = try await store(transport).snapshot()
        // ほかの中身と取り違えない。持たないので、次に読むときは取りに行き直す
        await #expect(throws: (any Error).self) { try await snapshot.read("macs/mac-mini.json") }
        #expect(try await snapshot.read("macs/mac-mini.json")?.data == Self.mac)
    }

    @Test func listsAndReportsMissingAndWrongKind() async throws {
        let macSHA = GitBlobSHA.of(Self.mac)
        let transport = StubTransport([
            Self.root(macs: "aaa111", etag: "\"r1\""),
            Self.tree("aaa111", [
                .init(path: "mac-mini.json", sha: macSHA), .init(path: "old", type: "tree", sha: "ccc333"),
                .init(path: "lib", type: "commit", sha: "ddd444")
            ])
        ])
        let snapshot = try await store(transport).snapshot()
        let entries = [
            DirectoryEntry(name: "mac-mini.json", path: "macs/mac-mini.json", kind: .file, sha: macSHA),
            DirectoryEntry(name: "old", path: "macs/old", kind: .directory, sha: "ccc333")
        ]
        // サブモジュールなどは並べない。tree は件数で切れないので、`listAll` も同じ
        #expect(try await snapshot.list("macs") == entries)
        #expect(try await snapshot.listAll("macs") == entries)
        #expect(try await snapshot.read("macs/missing.json") == nil)
        #expect(try await snapshot.list("missing") == nil)
        // 途中がファイルなら、無いものとする
        #expect(try await snapshot.read("version.json/x.json") == nil)
        await #expect(throws: StateStoreError.wrongKind) { try await snapshot.read("macs") }
        await #expect(throws: StateStoreError.wrongKind) { try await snapshot.list("version.json") }
        await #expect(throws: StateStoreError.invalidPath) { try await snapshot.read("../macs/mac-mini.json") }
        #expect(transport.requests.count == 2)
    }

    @Test func refusesWritesWithoutSending() async throws {
        let transport = StubTransport([Self.root(macs: "aaa111", etag: "\"r1\"")])
        let snapshot = try await store(transport).snapshot()
        await #expect(throws: (any Error).self) {
            try await snapshot.write("version.json", data: Self.version, replacing: GitBlobSHA.of(Self.version), message: "m")
        }
        #expect(transport.requests.count == 1)
    }

    @Test func missingRepositoryHasNoFiles() async throws {
        let transport = StubTransport([.init(status: 404)])
        let snapshot = try await store(transport).snapshot()
        #expect(try await snapshot.read("version.json") == nil)
        #expect(try await snapshot.list("macs") == nil)
    }

    @Test func refusesTruncatedRootListing() async throws {
        let crowded = (0..<1_000).map { #"{"type":"file","name":"f\#($0)","path":"f\#($0)","sha":"a\#($0)"}"# }
        let transport = StubTransport([.json(200, "[\(crowded.joined(separator: ","))]")])
        await #expect(throws: (any Error).self) { try await store(transport).snapshot() }
    }

    @Test func objectCacheKeepsObjectsInUseAcrossGenerations() async {
        let cache = GitObjectCache(generationCount: 2)
        let object = { (text: String) in GitObjectCache.Object.blob(Data(text.utf8)) }
        await cache.store(object("a"), for: .blob("a"))
        await cache.store(object("b"), for: .blob("b"))
        // 今の世代がいっぱいなので、前の世代に回す
        await cache.store(object("c"), for: .blob("c"))
        // 前の世代から読んだものは、今の世代に移す
        #expect(await cache.object(for: .blob("a")) == object("a"))
        await cache.store(object("d"), for: .blob("d"))
        // 2 つの世代のあいだ使わなかったものは捨てる
        #expect(await cache.object(for: .blob("b")) == nil)
        #expect(await cache.object(for: .blob("a")) == object("a"))
        #expect(await cache.object(for: .blob("c")) == object("c"))
        #expect(await cache.object(for: .blob("d")) == object("d"))
        // tree と blob は別のものとして持つ
        #expect(await cache.object(for: .tree("d")) == nil)
    }

    @Test func objectCacheSkipsTooLargeObject() async {
        let cache = GitObjectCache(generationSize: 4)
        await cache.store(.blob(Data("12345".utf8)), for: .blob("large"))
        #expect(await cache.object(for: .blob("large")) == nil)
    }
}
