import AskHubProtocol
@testable import AskHubStateStore
import Foundation
import Testing

struct GitHubContentsStoreTests {
    /// テスト用の値。本物のトークンではない
    private static let token = "test-token-not-real-0123456789"
    private static let repository = RepositoryFullName(rawValue: "shilokuma-inc/askhub-state")!
    private static let now = Date(timeIntervalSince1970: 1_793_700_000)

    private func store(_ transport: StubTransport, branch: String? = nil, budget: WriteBudget? = nil) -> GitHubContentsStore {
        GitHubContentsStore(
            repository: Self.repository,
            branch: branch,
            transport: transport,
            budget: budget,
            now: { Self.now },
            token: { Self.token }
        )
    }

    /// Contents API のファイルの応答。content は 60 文字ごとに改行した base64
    private static func fileReply(_ text: String, sha: String, etag: String? = nil) -> StubTransport.Reply {
        let base64 = Data(text.utf8).base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 60).map { offset in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            return String(base64[start..<(base64.index(start, offsetBy: 60, limitedBy: base64.endIndex) ?? base64.endIndex)])
        }
        let wrapped = lines.joined(separator: "\n")
        let body = try? JSONSerialization.data(withJSONObject: [
            "type": "file", "name": "x.json", "path": "x.json", "sha": sha, "encoding": "base64", "content": wrapped
        ])
        return StubTransport.Reply(status: 200, headers: etag.map { ["ETag": $0] } ?? [:], body: body ?? Data())
    }

    // MARK: - 読み取り

    @Test func readsFileAndSendsHeaders() async throws {
        let text = String(repeating: "{\"v\":1}", count: 20)
        let transport = StubTransport([Self.fileReply(text, sha: "abc123")])
        let blob = try await store(transport, branch: "main").read("macs/mac-mini.json")
        #expect(blob == StoredBlob(data: Data(text.utf8), sha: "abc123"))
        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.absoluteString == "https://api.github.com/repos/shilokuma-inc/askhub-state/contents/macs/mac-mini.json?ref=main")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(request.value(forHTTPHeaderField: "X-GitHub-Api-Version") == "2022-11-28")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func sendsETagAndReusesContentsOn304() async throws {
        let transport = StubTransport([Self.fileReply("{}", sha: "s1", etag: "\"e1\""), .init(status: 304)])
        let store = store(transport)
        let first = try await store.read("version.json")
        let second = try await store.read("version.json")
        #expect(first == second)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"e1\"")
    }

    @Test func refetchesChangedContentsAndSendsNewETag() async throws {
        let transport = StubTransport([
            Self.fileReply("{}", sha: "s1", etag: "\"e1\""),
            Self.fileReply("{\"v\":2}", sha: "s2", etag: "\"e2\""),
            .init(status: 304)
        ])
        let store = store(transport)
        _ = try await store.read("version.json")
        #expect(try await store.read("version.json") == StoredBlob(data: Data("{\"v\":2}".utf8), sha: "s2"))
        #expect(try await store.read("version.json") == StoredBlob(data: Data("{\"v\":2}".utf8), sha: "s2"))
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "\"e2\"")
    }

    @Test func missingFileIsNilAndForgetsETag() async throws {
        let transport = StubTransport([
            Self.fileReply("{}", sha: "s1", etag: "\"e1\""), .init(status: 404), .init(status: 404)
        ])
        let store = store(transport)
        _ = try await store.read("version.json")
        #expect(try await store.read("version.json") == nil)
        #expect(try await store.read("version.json") == nil)
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func listsDirectoryAndRejectsWrongKind() async throws {
        let listing = """
        [{"type":"file","name":"1.json","path":"a/1.json","sha":"s1"},{"type":"dir","name":"b","path":"a/b","sha":"s2"},\
        {"type":"symlink","name":"c","path":"a/c","sha":"s3"}]
        """
        let transport = StubTransport([.json(200, listing), .json(200, listing), Self.fileReply("{}", sha: "s"), .init(status: 404)])
        let store = store(transport)
        #expect(try await store.list("a") == [
            DirectoryEntry(name: "1.json", path: "a/1.json", kind: .file, sha: "s1"),
            DirectoryEntry(name: "b", path: "a/b", kind: .directory, sha: "s2")
        ])
        await #expect(throws: StateStoreError.wrongKind) { try await store.read("a") }
        await #expect(throws: StateStoreError.wrongKind) { try await store.list("a/1.json") }
        #expect(try await store.list("missing") == nil)
    }

    @Test func readsLargeFileAsRaw() async throws {
        // 1 MB を超えるファイルは、encoding が none で content が空で返る。raw の形で読み直す
        let raw = Data(repeating: 0xFF, count: 2_000_000)
        let sha = GitBlobSHA.of(raw)
        let large = #"{"type":"file","name":"1","path":"attachments/k/n/1","sha":"\#(sha)","encoding":"none","content":""}"#
        let transport = StubTransport([.json(200, large), .init(status: 200, headers: [:], body: raw)])
        let blob = try await store(transport, branch: "main").read("attachments/k/n/1")
        #expect(blob == StoredBlob(data: raw, sha: sha))
        #expect(transport.requests.last?.value(forHTTPHeaderField: "Accept") == "application/vnd.github.raw+json")
        #expect(transport.requests.last?.url?.query?.contains("ref=main") == true)
    }

    @Test func refusesRawContentsThatDoNotMatchVersion() async throws {
        // 版を読んでから中身を読むまでの間に書き換わったら、古い版の付いた新しい中身を返さない
        let old = GitBlobSHA.of(Data("old".utf8))
        let large = #"{"type":"file","name":"1","path":"attachments/k/n/1","sha":"\#(old)","encoding":"none","content":""}"#
        let transport = StubTransport([.json(200, large), .init(status: 200, headers: [:], body: Data("new".utf8))])
        await #expect(throws: (any Error).self) { try await store(transport).read("attachments/k/n/1") }
    }

    @Test func listsFilesUnderDirectoryThroughGitTrees() async throws {
        let root = """
        [{"type":"dir","name":"intents","path":"intents","sha":"abc123"},\
        {"type":"file","name":"version.json","path":"version.json","sha":"v"}]
        """
        let tree = """
        {"sha":"abc123","truncated":false,"tree":[{"path":"k1","type":"tree","sha":"t1"},\
        {"path":"k1/01.json","type":"blob","sha":"s1"},{"path":"k2/02.json","type":"blob","sha":"s2"}]}
        """
        let transport = StubTransport([.json(200, root), .json(200, tree)])
        let files = try await store(transport, branch: "main").listFiles(under: "intents")
        #expect(files == [
            DirectoryEntry(name: "01.json", path: "intents/k1/01.json", kind: .file, sha: "s1"),
            DirectoryEntry(name: "02.json", path: "intents/k2/02.json", kind: .file, sha: "s2")
        ])
        // 親（リポジトリの直下）の一覧から tree の sha を読み、Git Trees API で下まで読む
        let urls = transport.requests.compactMap(\.url?.absoluteString)
        let first = urls.first ?? ""
        #expect(first.hasSuffix("/repos/shilokuma-inc/askhub-state/contents/?ref=main") || first.hasSuffix("/contents?ref=main"))
        #expect(urls.last?.hasSuffix("/repos/shilokuma-inc/askhub-state/git/trees/abc123?recursive=1") == true)
    }

    @Test func listsAllEntriesDirectlyUnderDirectoryThroughGitTrees() async throws {
        let parent = #"[{"type":"dir","name":"epics","path":"repos/o/r/epics","sha":"abc123"}]"#
        let tree = """
        {"sha":"abc123","truncated":false,"tree":[{"path":"01A","type":"tree","sha":"t1"},\
        {"path":"README","type":"blob","sha":"s1"},{"path":"lib","type":"commit","sha":"c1"}]}
        """
        let transport = StubTransport([.json(200, parent), .json(200, tree)])
        let entries = try await store(transport).listAll("repos/o/r/epics")
        // 直下のディレクトリとファイルだけ（下の階層は辿らない）
        #expect(entries == [
            DirectoryEntry(name: "01A", path: "repos/o/r/epics/01A", kind: .directory, sha: "t1"),
            DirectoryEntry(name: "README", path: "repos/o/r/epics/README", kind: .file, sha: "s1")
        ])
        let urls = transport.requests.compactMap(\.url?.absoluteString)
        #expect(urls.first?.contains("/contents/repos/o/r") == true)
        #expect(urls.last?.hasSuffix("/git/trees/abc123") == true)
    }

    @Test func listAllFindsDirectoryBeyondContentsListLimit() async throws {
        // 親の一覧が 1,000 件で切れて目的のディレクトリが載っていなければ、親の直下を Git Trees API で読み直して探す
        let crowded = (0..<1_000).map { #"{"type":"dir","name":"j\#($0)","path":"a/b/j\#($0)","sha":"x\#($0)"}"# }
        let grandparent = #"[{"type":"dir","name":"b","path":"a/b","sha":"bbb111"}]"#
        let parentTree = #"{"sha":"bbb111","truncated":false,"tree":[{"path":"target","type":"tree","sha":"ccc222"}]}"#
        let targetTree = #"{"sha":"ccc222","truncated":false,"tree":[{"path":"1.json","type":"blob","sha":"s1"}]}"#
        let transport = StubTransport([
            .json(200, "[\(crowded.joined(separator: ","))]"), .json(200, grandparent), .json(200, parentTree), .json(200, targetTree)
        ])
        let entries = try await store(transport).listAll("a/b/target")
        #expect(entries == [DirectoryEntry(name: "1.json", path: "a/b/target/1.json", kind: .file, sha: "s1")])
    }

    @Test func treeCacheIsKeptPerDirectory() async throws {
        // 同じ中身の tree が別のディレクトリにあっても、前のディレクトリのパスの一覧を使い回さない
        let root = #"[{"type":"dir","name":"x","path":"x","sha":"ddd333"},{"type":"dir","name":"y","path":"y","sha":"ddd333"}]"#
        let tree = #"{"sha":"ddd333","truncated":false,"tree":[{"path":"1.json","type":"blob","sha":"s1"}]}"#
        let transport = StubTransport([
            .json(200, root), .json(200, tree, headers: ["ETag": "\"e1\""]), .json(200, root), .json(200, tree, headers: ["ETag": "\"e1\""])
        ])
        let store = store(transport)
        #expect(try await store.listAll("x")?.map(\.path) == ["x/1.json"])
        #expect(try await store.listAll("y")?.map(\.path) == ["y/1.json"])
        #expect(transport.requests.last?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func listFilesRefusesTruncatedTreeAndReportsMissingDirectory() async throws {
        let root = #"[{"type":"dir","name":"intents","path":"intents","sha":"abc123"}]"#
        let truncated = #"{"sha":"abc123","truncated":true,"tree":[]}"#
        let transport = StubTransport([.json(200, root), .json(200, truncated), .json(200, root)])
        let store = store(transport)
        // 一覧が途中で切れたら、足りない一覧で処理を進めない
        await #expect(throws: (any Error).self) { try await store.listFiles(under: "intents") }
        #expect(try await store.listFiles(under: "consumed") == nil)
        await #expect(throws: StateStoreError.invalidPath) { try await store.listFiles(under: "../intents") }
    }

    // MARK: - 書き込み

    @Test func writesBase64WithShaAndForgetsETag() async throws {
        let transport = StubTransport([
            Self.fileReply("{}", sha: "s1", etag: "\"e1\""),
            .json(200, #"{"content":{"sha":"s2"},"commit":{"sha":"c1"}}"#),
            Self.fileReply("{\"a\":1}", sha: "s2")
        ])
        let store = store(transport, branch: "main")
        _ = try await store.read("repos/a/b/repo.json")
        let sha = try await store.write("repos/a/b/repo.json", data: Data("{\"a\":1}".utf8), replacing: "s1", message: "[state] 更新")
        #expect(sha == "s2")
        let request = transport.requests[1]
        #expect(request.httpMethod == "PUT")
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body == ["message": "[state] 更新", "content": Data("{\"a\":1}".utf8).base64EncodedString(), "sha": "s1", "branch": "main"])
        // 書いた後は、古い ETag を付けずに読み直す
        _ = try await store.read("repos/a/b/repo.json")
        #expect(transport.requests[2].value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test func createOmitsSha() async throws {
        let transport = StubTransport([.json(201, #"{"content":{"sha":"s1"}}"#)])
        _ = try await store(transport).write("version.json", data: Data("{}".utf8), replacing: nil, message: "作る")
        let request = try #require(transport.requests.first)
        let body = try #require(request.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body["sha"] == nil)
        #expect(body["branch"] == nil)
    }

    @Test func writeConflictsAreReported() async throws {
        let transport = StubTransport([
            .json(409, #"{"message":"is at abc but expected def"}"#),
            .json(422, #"{"message":"Invalid request.\n\n\"sha\" wasn't supplied."}"#),
            .json(422, #"{"message":"Validation Failed"}"#),
            .json(404, #"{"message":"Not Found"}"#)
        ])
        let store = store(transport)
        let write = { () async throws(StateStoreError) -> String in
            try await store.write("version.json", data: Data(), replacing: nil, message: "m")
        }
        await #expect(throws: StateStoreError.conflict) { try await write() }
        await #expect(throws: StateStoreError.conflict) { try await write() }
        await #expect(throws: StateStoreError.unexpected(status: 422, message: "Validation Failed")) { try await write() }
        await #expect(throws: StateStoreError.notFound) { try await write() }
    }

    @Test func budgetStopsWritesBeforeSending() async throws {
        let transport = StubTransport([.json(201, #"{"content":{"sha":"s1"}}"#)])
        let store = store(transport, budget: WriteBudget(limits: .init(perMinute: 1, perHour: 10)))
        _ = try await store.write("a.json", data: Data(), replacing: nil, message: "m")
        await #expect(throws: StateStoreError.budgetExhausted(retryAfter: .seconds(60))) {
            try await store.write("b.json", data: Data(), replacing: nil, message: "m")
        }
        #expect(transport.requests.count == 1)
    }

    // MARK: - 失敗の分け方

    struct FailureCase: Sendable, CustomTestStringConvertible {
        let reply: StubTransport.Reply
        let expected: StateStoreError

        var testDescription: String { "\(reply.status) → \(expected)" }

        init(_ status: Int, headers: [String: String] = [:], body: String = "{}", expect expected: StateStoreError) {
            reply = .json(status, body, headers: headers)
            self.expected = expected
        }
    }

    private static let primaryRateLimit = ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1793700030"]
    private static let secondaryRateLimit = #"{"message":"You have exceeded a secondary rate limit."}"#
    private static let notAccessible = "Resource not accessible by personal access token"

    @Test(arguments: [
        FailureCase(401, expect: .unauthorized),
        // 一次の上限は、リセットの時刻（30 秒後）に 1 秒の余裕を足して待つ
        FailureCase(403, headers: primaryRateLimit, expect: .rateLimited(retryAfter: .seconds(31))),
        FailureCase(403, headers: ["Retry-After": "12"], expect: .rateLimited(retryAfter: .seconds(12))),
        // 二次の上限は、ヘッダーの無い 403 で返ることがある
        FailureCase(403, body: secondaryRateLimit, expect: .rateLimited(retryAfter: .seconds(60))),
        FailureCase(403, body: #"{"message":"\#(notAccessible)"}"#, expect: .forbidden(message: notAccessible)),
        FailureCase(429, expect: .rateLimited(retryAfter: .seconds(60))),
        FailureCase(301, headers: ["Location": "https://api.github.com/repositories/1/contents/x"], expect: .redirected(status: 301)),
        FailureCase(502, body: "<html>", expect: .serverError(status: 502)),
        FailureCase(418, expect: .unexpected(status: 418, message: nil))
    ])
    func classifiesFailures(_ failure: FailureCase) async throws {
        let transport = StubTransport([failure.reply])
        await #expect(throws: failure.expected) { try await store(transport).read("version.json") }
    }

    @Test(arguments: ["", "/a.json", "a//b.json", "a/../b.json", "./a.json", "a/..", "a b.json", "a/b\n", "日本.json", "a?b", "a%2Fb"])
    func rejectsUnsafePathsWithoutSending(path: String) async throws {
        let transport = StubTransport([])
        let store = store(transport)
        await #expect(throws: StateStoreError.invalidPath) { try await store.read(path) }
        await #expect(throws: StateStoreError.invalidPath) { try await store.write(path, data: Data(), replacing: nil, message: "m") }
        #expect(transport.requests.isEmpty)
    }

    @Test func failuresDoNotCarryToken() async throws {
        let transport = StubTransport([.json(403, #"{"message":"Bad credentials"}"#)])
        let failingTokenStore = GitHubContentsStore(repository: Self.repository, transport: StubTransport([]), budget: nil) {
            throw URLError(.userAuthenticationRequired)
        }
        await #expect(throws: StateStoreError.tokenUnavailable) { try await failingTokenStore.read("version.json") }
        do {
            _ = try await store(transport).read("version.json")
            Issue.record("失敗するはず")
        } catch {
            #expect(!"\(error)".contains(Self.token))
            #expect(!String(reflecting: error).contains(Self.token))
        }
        // トークンは URL に入れない
        #expect(transport.requests.allSatisfy { $0.url?.absoluteString.contains(Self.token) == false })
    }

    @Test func tokenFailuresAreNotCountedAndCancellationIsKept() async throws {
        let budget = WriteBudget(limits: .init(perMinute: 1, perHour: 10))
        let failing = GitHubContentsStore(repository: Self.repository, transport: StubTransport([]), budget: budget) {
            throw URLError(.userAuthenticationRequired)
        }
        await #expect(throws: StateStoreError.tokenUnavailable) {
            try await failing.write("a.json", data: Data(), replacing: nil, message: "m")
        }
        // トークンを読めなかった書き込みは、予算に数えない
        let transport = StubTransport([.json(201, #"{"content":{"sha":"s1"}}"#)])
        _ = try await store(transport, budget: budget).write("a.json", data: Data(), replacing: nil, message: "m")
        let cancelled = GitHubContentsStore(repository: Self.repository, transport: StubTransport([]), budget: nil) {
            throw CancellationError()
        }
        await #expect(throws: StateStoreError.cancelled) { try await cancelled.read("version.json") }
    }

    @Test func cacheKeepsWithinSizeLimit() async {
        let cache = ETagCache()
        let half = Contents.file(StoredBlob(data: Data(count: ETagCache.sizeLimit / 2 + 1), sha: "s"))
        await cache.store("a.json", ETagCache.Entry(etag: "a", contents: half))
        await cache.store("b.json", ETagCache.Entry(etag: "b", contents: half))
        // 合わせて上限を超えるので、前のものを捨ててから持つ
        #expect(await cache.entry(for: "a.json") == nil)
        #expect(await cache.entry(for: "b.json")?.etag == "b")
        let tooLarge = Contents.file(StoredBlob(data: Data(count: ETagCache.sizeLimit + 1), sha: "s"))
        await cache.store("c.json", ETagCache.Entry(etag: "c", contents: tooLarge))
        #expect(await cache.entry(for: "c.json") == nil)
    }

    @Test func transportFailuresAreClassified() async throws {
        let transport = StubTransport([])
        await #expect(throws: StateStoreError.transport("URLError \(URLError.badServerResponse.rawValue)")) {
            try await store(transport).read("version.json")
        }
    }
}
