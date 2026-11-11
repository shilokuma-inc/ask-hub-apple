import AskHubProtocol
import CryptoKit
import Foundation

/// GitHub の Contents API で状態リポジトリを読み書きする。
///
/// - 読み取りは ETag を付ける。変わっていなければ 304 が返り、上限に数えられない
/// - 書き込みは読んだときの版（sha）を付ける。版が合わない・同じブランチへの書き込みがぶつかったときは 409 が返る
///   （Contents API は同じブランチへの並んだ書き込みもぶつかる）ので、`StateFileStore` が読み直してやり直す
/// - ディレクトリの一覧は 1,000 件まで（Contents API の上限）。増え続けるディレクトリ（人の意図・epic・ジョブなど）は、
///   `listFiles(under:)`（下の階層まで）か `listAll(_:)`（直下だけ）で Git Trees API から読む（10 万件・7 MB まで）
/// - 1 回で多くのファイルを読む処理は、`snapshot()` の写しから読む。ETag の 304 でも 1 回ずつ往復するので、
///   sha で中身が決まる tree と blob を使い回し、要求そのものを減らす
public struct GitHubContentsStore: StateStore {
    public let repository: RepositoryFullName
    /// 読み書きするブランチ。nil ならリポジトリの既定のブランチ
    public let branch: String?

    private let apiBase: URL
    private let transport: any HTTPTransport
    private let token: @Sendable () async throws -> String
    private let budget: WriteBudget?
    let now: @Sendable () -> Date
    private let cache = ETagCache()
    /// sha で中身が決まる tree と blob（`snapshot()` の写しが使い回す）
    let objects: GitObjectCache

    /// `token` は要求のたびに Keychain などから読む。値はログ・URL・エラーに出さない。
    /// `objectsDirectory` を渡すと、写しが読んだ tree と blob をそのディレクトリのファイルにも持ち、起動し直しても GitHub から読み直さない
    /// （中身は状態リポジトリのファイルだけで、トークンは書かない）
    public init(
        repository: RepositoryFullName,
        branch: String? = nil,
        apiBase: URL = URL(string: "https://api.github.com")!,
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        budget: WriteBudget?,
        objectsDirectory: URL? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        token: @escaping @Sendable () async throws -> String
    ) {
        self.repository = repository
        self.branch = branch
        self.apiBase = apiBase
        self.transport = transport
        self.budget = budget
        objects = GitObjectCache(directory: objectsDirectory)
        self.now = now
        self.token = token
    }

    public func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        guard !path.isEmpty else { throw .invalidPath }
        switch try await get(path) {
        case .missing: return nil
        case let .file(blob): return blob
        case let .largeFile(sha): return try await readRaw(path, sha: sha)
        case .directory: throw .wrongKind
        }
    }

    public func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        guard !directory.isEmpty else { throw .invalidPath }
        switch try await get(directory) {
        case .missing: return nil
        case let .directory(entries, _): return entries
        case .file, .largeFile: throw .wrongKind
        }
    }

    /// ディレクトリの下のファイルをすべて並べる。親の一覧からディレクトリの tree の sha を読み、Git Trees API で下まで読む
    public func listFiles(under directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        guard let sha = try await treeSHA(of: directory) else { return nil }
        return try await tree(sha: sha, under: directory, recursive: true)
    }

    /// ディレクトリの直下をすべて並べる。親の一覧からディレクトリの tree の sha を読み、Git Trees API で直下だけ読む
    public func listAll(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        guard let sha = try await treeSHA(of: directory) else { return nil }
        return try await tree(sha: sha, under: directory, recursive: false)
    }

    /// Contents API のディレクトリの一覧の上限
    static let contentsListLimit = 1_000

    /// 親の一覧から読む、ディレクトリの tree の sha。ディレクトリが無ければ nil
    private func treeSHA(of directory: String) async throws(StateStoreError) -> String? {
        guard StatePathCheck.isSafe(directory) else { throw .invalidPath }
        let parts = directory.split(separator: "/").map(String.init)
        let parent = parts.dropLast().joined(separator: "/")
        var siblings: [DirectoryEntry]
        let listed: Int
        switch try await get(parent) {
        case .missing: return nil
        case let .directory(entries, count):
            siblings = entries
            listed = count
        case .file, .largeFile: throw .wrongKind
        }
        // 親の一覧が上限で切れていれば（ファイルとディレクトリ以外も数える）、見つからなくても無いとは言えない。
        // 親の直下を Git Trees API で読み直して探す。状態リポジトリの直下は決まった数件なので、切れていれば決まりと違う
        if !siblings.contains(where: { $0.name == parts.last }), listed >= Self.contentsListLimit {
            guard !parent.isEmpty else { throw .unexpected(status: 200, message: "状態リポジトリの直下の一覧が 1,000 件で切れた（決まりでは数件）") }
            siblings = try await listAll(parent) ?? []
        }
        guard let tree = siblings.first(where: { $0.name == parts.last }) else { return nil }
        guard tree.kind == .directory else { throw .wrongKind }
        return tree.sha
    }

    public func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        guard StatePathCheck.isSafe(path) else { throw .invalidPath }
        let body = WriteBody(message: message, content: data.base64EncodedString(), sha: sha, branch: branch)
        var request = try await makeRequest(path: path, query: [])
        // 予算は GitHub に送る書き込みだけを数える（トークンを読めなかった書き込みは数えない）
        try await budget?.reserve(now: now())
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(body)
        } catch {
            throw .unexpected(status: 0, message: "書き込みの本文を作れない")
        }
        let (responseBody, response) = try await send(request)
        // 書いた後の内容の ETag は分からないので、次の読み取りは取り直す
        await cache.remove(path)
        guard (200..<300).contains(response.statusCode) else {
            throw StateStoreError.classify(response, body: responseBody, now: now())
        }
        guard let written = try? JSONDecoder().decode(WriteResponse.self, from: responseBody) else {
            throw .unexpected(status: response.statusCode, message: "書き込みの応答を読めない")
        }
        return written.content.sha
    }

    // MARK: - 読み取り

    /// `path` が空なら、リポジトリの直下の一覧（`listFiles(under:)` と `snapshot()` が使う）
    func get(_ path: String) async throws(StateStoreError) -> Contents {
        guard path.isEmpty || StatePathCheck.isSafe(path) else { throw .invalidPath }
        let request = try await makeRequest(path: path, query: branch.map { [URLQueryItem(name: "ref", value: $0)] } ?? [])
        return try await fetch(request, cacheKey: path, decode: Self.decodeContents)
    }

    /// tree の下。`recursive` なら下の階層までのファイル（blob）、そうでなければ直下のファイルとディレクトリ。
    /// tree は sha で決まり中身が変わらないので、前に読んだものがあれば取りに行かない
    private func tree(sha: String, under directory: String, recursive: Bool) async throws(StateStoreError) -> [DirectoryEntry] {
        guard Self.isObjectSHA(sha) else { throw .unexpected(status: 200, message: "tree の sha の形が違う") }
        // `:` は状態リポジトリのパスに使わないので、ファイルの中身の鍵とぶつからない。同じ中身の tree が別のディレクトリにもあり得るので、
        // 読んだディレクトリも鍵に入れる（一覧のパスはディレクトリから作るため）
        let cacheKey = "\(recursive ? "tree" : "entries"):\(sha):\(directory)"
        if case let .directory(entries, _)? = await cache.entry(for: cacheKey)?.contents { return entries }
        let query = recursive ? [URLQueryItem(name: "recursive", value: "1")] : []
        let request = try await makeRequest(apiPath: "git/trees/\(sha)", query: query)
        let contents = try await fetch(request, cacheKey: cacheKey) { body throws(StateStoreError) in
            let entries = try Self.decodeTree(body, under: directory, recursive: recursive)
            return .directory(entries, listed: entries.count)
        }
        guard case let .directory(entries, _) = contents else { throw .wrongKind }
        return entries
    }

    /// Git のオブジェクトの sha の形（16 進の小文字）か。URL のパスに入れる前に確かめる
    static func isObjectSHA(_ sha: String) -> Bool {
        !sha.isEmpty && sha.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    static func decodeTree(
        _ body: Data,
        under directory: String,
        recursive: Bool = true
    ) throws(StateStoreError) -> [DirectoryEntry] {
        guard let tree = try? JSONDecoder().decode(TreeResponse.self, from: body) else {
            throw .unexpected(status: 200, message: "tree の応答を読めない")
        }
        // 上限（10 万件・7 MB）を超えると、一覧が途中で切れる。足りない一覧で処理を進めない
        guard !tree.truncated else { throw .unexpected(status: 200, message: "ディレクトリの中が多すぎて、一覧が途中で切れた") }
        // 下の階層まで読むときはファイルだけ、直下だけのときはファイルとディレクトリ（サブモジュールなどは並べない）
        let kinds: [String: DirectoryEntry.Kind] = recursive ? ["blob": .file] : ["blob": .file, "tree": .directory]
        return tree.tree.compactMap { entry in
            guard let kind = kinds[entry.type] else { return nil }
            let name = String(entry.path.split(separator: "/").last ?? "")
            return DirectoryEntry(name: name, path: "\(directory)/\(entry.path)", kind: kind, sha: entry.sha)
        }
    }

    /// ETag を付けて読む。変わっていなければ、前に読んだ中身を返す
    private func fetch(
        _ request: URLRequest,
        cacheKey: String,
        decode: (Data) throws(StateStoreError) -> Contents
    ) async throws(StateStoreError) -> Contents {
        var request = request
        let cached = await cache.entry(for: cacheKey)
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let (body, response) = try await send(request)
        switch response.statusCode {
        case 304:
            guard let cached else { throw .unexpected(status: 304, message: "ETag を付けていないのに 304 が返った") }
            return cached.contents
        case 404:
            await cache.remove(cacheKey)
            return .missing
        case 200:
            let contents = try decode(body)
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                await cache.store(cacheKey, ETagCache.Entry(etag: etag, contents: contents))
            }
            return contents
        default:
            throw StateStoreError.classify(response, body: body, now: now())
        }
    }

    static func decodeContents(_ body: Data) throws(StateStoreError) -> Contents {
        if let entries = try? JSONDecoder().decode([ContentsEntry].self, from: body) {
            // ファイルとディレクトリだけを並べる（シンボリックリンクとサブモジュールは状態リポジトリに置かない）
            let listed = entries.compactMap { entry -> DirectoryEntry? in
                guard let kind = DirectoryEntry.Kind(rawValue: entry.type) else { return nil }
                return DirectoryEntry(name: entry.name, path: entry.path, kind: kind, sha: entry.sha)
            }
            return .directory(listed, listed: entries.count)
        }
        guard let file = try? JSONDecoder().decode(ContentsEntry.self, from: body) else {
            throw .unexpected(status: 200, message: "内容の応答を読めない")
        }
        guard file.type == "file" else { throw .wrongKind }
        // 1 MB を超えるファイルは、encoding が none で content が空で返る。中身は raw の形で読み直す
        if file.encoding == "none" { return .largeFile(sha: file.sha) }
        // content は base64 を 60 文字ごとに改行した文字列（LEARNINGS.md）
        guard file.encoding == "base64", let content = file.content,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw .unexpected(status: 200, message: "ファイルの中身を読めない（\(file.encoding ?? "encoding なし")）")
        }
        return .file(StoredBlob(data: data, sha: file.sha))
    }

    /// 1 MB を超えるファイル（添付など）を raw の形で読む（Contents API は 1〜100 MB のファイルを raw でだけ返す）。
    /// 中身は ETag で持たない（大きく、何度も読まないため）
    private func readRaw(_ path: String, sha: String) async throws(StateStoreError) -> StoredBlob? {
        var request = try await makeRequest(path: path, query: branch.map { [URLQueryItem(name: "ref", value: $0)] } ?? [])
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (body, response) = try await send(request)
        switch response.statusCode {
        case 200:
            // 版を読んでから中身を読むまでの間に書き換わっていたら、新しい中身に古い版を付けてしまう
            guard GitBlobSHA.of(body) == sha else { throw .unexpected(status: 200, message: "raw で読んだ中身が、読んだときの版と合わない（読み直す）") }
            return StoredBlob(data: body, sha: sha)
        case 404: return nil
        default: throw StateStoreError.classify(response, body: body, now: now())
        }
    }

    // MARK: - 要求

    /// Contents API の要求。パスの部品は英数字と ._- だけなので、そのまま URL に入れられる
    private func makeRequest(path: String, query: [URLQueryItem]) async throws(StateStoreError) -> URLRequest {
        try await makeRequest(apiPath: "contents/\(path)", query: query)
    }

    /// リポジトリの API の要求（`apiPath` は `repos/<owner>/<repo>/` からのパス）
    func makeRequest(apiPath: String, query: [URLQueryItem]) async throws(StateStoreError) -> URLRequest {
        var components = URLComponents(
            url: apiBase.appendingPathComponent("repos/\(repository.owner)/\(repository.name)/\(apiPath)"),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw .invalidPath }
        let token: String
        do {
            token = try await self.token()
        } catch is CancellationError {
            throw .cancelled
        } catch {
            throw .tokenUnavailable
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    func send(_ request: URLRequest) async throws(StateStoreError) -> (Data, HTTPURLResponse) {
        do {
            return try await transport.send(request)
        } catch is CancellationError {
            throw .cancelled
        } catch let error as URLError where error.code == .cancelled {
            throw .cancelled
        } catch let error as URLError {
            throw .transport("URLError \(error.code.rawValue)")
        } catch {
            throw .transport(String(describing: type(of: error)))
        }
    }
}

/// Git の blob の sha（`blob <長さ>\0` を前に付けた SHA-1 の 16 進の小文字）
enum GitBlobSHA {
    static func of(_ data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

enum Contents: Sendable, Equatable {
    case missing
    case file(StoredBlob)
    /// 1 MB を超えるファイル。中身は raw の形で読み直す
    case largeFile(sha: String)
    /// `listed` は応答に載っていた件数（並べないシンボリックリンクなども数える。Contents API の上限で切れたかを見る）
    case directory([DirectoryEntry], listed: Int)
}

private struct ContentsEntry: Decodable {
    let type: String
    let name: String
    let path: String
    let sha: String
    let encoding: String?
    let content: String?
}

private struct TreeResponse: Decodable {
    struct Entry: Decodable {
        let path: String
        let type: String
        let sha: String
    }

    let tree: [Entry]
    let truncated: Bool
}

private struct WriteBody: Encodable {
    let message: String
    let content: String
    let sha: String?
    let branch: String?
}

private struct WriteResponse: Decodable {
    struct Content: Decodable {
        let sha: String
    }

    let content: Content
}

/// 読んだときの ETag と中身。メモリーにだけ持つ
actor ETagCache {
    struct Entry: Sendable {
        let etag: String
        let contents: Contents

        /// 持っている中身の大きさの目安
        var size: Int {
            switch contents {
            case .missing, .largeFile: 0
            case let .file(blob): blob.data.count
            case let .directory(entries, _): entries.reduce(0) { $0 + $1.name.utf8.count + $1.path.utf8.count + $1.sha.utf8.count }
            }
        }
    }

    /// 持ちすぎないよう、どちらかを超えたら空にする（状態リポジトリのファイルの数と大きさより十分に大きい）
    static let countLimit = 5_000
    static let sizeLimit = 32 * 1_024 * 1_024
    private var entries: [String: Entry] = [:]
    private var size = 0

    func entry(for path: String) -> Entry? { entries[path] }

    func store(_ path: String, _ entry: Entry) {
        remove(path)
        if entries.count >= Self.countLimit || size + entry.size > Self.sizeLimit {
            entries.removeAll()
            size = 0
        }
        // 1 つで上限を超えるものは持たない
        guard entry.size <= Self.sizeLimit else { return }
        entries[path] = entry
        size += entry.size
    }

    func remove(_ path: String) {
        if let removed = entries.removeValue(forKey: path) { size -= removed.size }
    }
}
