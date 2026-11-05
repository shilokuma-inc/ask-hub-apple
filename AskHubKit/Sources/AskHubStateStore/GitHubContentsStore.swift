import AskHubProtocol
import Foundation

/// GitHub の Contents API で状態リポジトリを読み書きする。
///
/// - 読み取りは ETag を付ける。変わっていなければ 304 が返り、上限に数えられない
/// - 書き込みは読んだときの版（sha）を付ける。版が合わない・同じブランチへの書き込みがぶつかったときは 409 が返る
///   （Contents API は同じブランチへの並んだ書き込みもぶつかる）ので、`StateFileStore` が読み直してやり直す
/// - ディレクトリの一覧は 1,000 件まで（Contents API の上限）。増え続けるディレクトリ（人の意図など）は、`listFiles(under:)` で
///   Git Trees API から読む（10 万件・7 MB まで）
public struct GitHubContentsStore: StateStore {
    public let repository: RepositoryFullName
    /// 読み書きするブランチ。nil ならリポジトリの既定のブランチ
    public let branch: String?

    private let apiBase: URL
    private let transport: any HTTPTransport
    private let token: @Sendable () async throws -> String
    private let budget: WriteBudget?
    private let now: @Sendable () -> Date
    private let cache = ETagCache()

    /// `token` は要求のたびに Keychain などから読む。値はログ・URL・エラーに出さない
    public init(
        repository: RepositoryFullName,
        branch: String? = nil,
        apiBase: URL = URL(string: "https://api.github.com")!,
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        budget: WriteBudget?,
        now: @escaping @Sendable () -> Date = { Date() },
        token: @escaping @Sendable () async throws -> String
    ) {
        self.repository = repository
        self.branch = branch
        self.apiBase = apiBase
        self.transport = transport
        self.budget = budget
        self.now = now
        self.token = token
    }

    public func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        guard !path.isEmpty else { throw .invalidPath }
        switch try await get(path) {
        case .missing: return nil
        case let .file(blob): return blob
        case .directory: throw .wrongKind
        }
    }

    public func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        guard !directory.isEmpty else { throw .invalidPath }
        switch try await get(directory) {
        case .missing: return nil
        case let .directory(entries): return entries
        case .file: throw .wrongKind
        }
    }

    /// ディレクトリの下のファイルをすべて並べる。親の一覧からディレクトリの tree の sha を読み、Git Trees API で下まで読む
    public func listFiles(under directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        guard StatePathCheck.isSafe(directory) else { throw .invalidPath }
        let parts = directory.split(separator: "/").map(String.init)
        let parent = parts.dropLast().joined(separator: "/")
        let siblings: [DirectoryEntry]
        switch try await get(parent) {
        case .missing: return nil
        case let .directory(entries): siblings = entries
        case .file: throw .wrongKind
        }
        guard let tree = siblings.first(where: { $0.name == parts.last }) else { return nil }
        guard tree.kind == .directory else { throw .wrongKind }
        return try await treeFiles(sha: tree.sha, under: directory)
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

    /// `path` が空なら、リポジトリの直下の一覧（`listFiles(under:)` だけが使う）
    private func get(_ path: String) async throws(StateStoreError) -> Contents {
        guard path.isEmpty || StatePathCheck.isSafe(path) else { throw .invalidPath }
        let request = try await makeRequest(path: path, query: branch.map { [URLQueryItem(name: "ref", value: $0)] } ?? [])
        return try await fetch(request, cacheKey: path, decode: Self.decodeContents)
    }

    /// tree の下のファイル（blob）。tree は sha で決まり中身が変わらないので、ETag でそのまま使い回せる
    private func treeFiles(sha: String, under directory: String) async throws(StateStoreError) -> [DirectoryEntry] {
        let isHex = sha.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
        guard !sha.isEmpty, isHex else { throw .unexpected(status: 200, message: "tree の sha の形が違う") }
        let request = try await makeRequest(apiPath: "git/trees/\(sha)", query: [URLQueryItem(name: "recursive", value: "1")])
        // `:` は状態リポジトリのパスに使わないので、ファイルの中身の鍵とぶつからない
        let contents = try await fetch(request, cacheKey: "tree:\(sha)") { body throws(StateStoreError) in
            try .directory(Self.decodeTree(body, under: directory))
        }
        guard case let .directory(entries) = contents else { throw .wrongKind }
        return entries
    }

    static func decodeTree(_ body: Data, under directory: String) throws(StateStoreError) -> [DirectoryEntry] {
        guard let tree = try? JSONDecoder().decode(TreeResponse.self, from: body) else {
            throw .unexpected(status: 200, message: "tree の応答を読めない")
        }
        // 上限（10 万件・7 MB）を超えると、一覧が途中で切れる。足りない一覧で処理を進めない
        guard !tree.truncated else { throw .unexpected(status: 200, message: "ディレクトリの中が多すぎて、一覧が途中で切れた") }
        return tree.tree.filter { $0.type == "blob" }.map { entry in
            let name = String(entry.path.split(separator: "/").last ?? "")
            return DirectoryEntry(name: name, path: "\(directory)/\(entry.path)", kind: .file, sha: entry.sha)
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
            return .directory(entries.compactMap { entry in
                guard let kind = DirectoryEntry.Kind(rawValue: entry.type) else { return nil }
                return DirectoryEntry(name: entry.name, path: entry.path, kind: kind, sha: entry.sha)
            })
        }
        guard let file = try? JSONDecoder().decode(ContentsEntry.self, from: body) else {
            throw .unexpected(status: 200, message: "内容の応答を読めない")
        }
        guard file.type == "file" else { throw .wrongKind }
        // content は base64 を 60 文字ごとに改行した文字列（LEARNINGS.md）。1 MB を超えるファイルは content が空で返る
        guard file.encoding == "base64", let content = file.content,
              let data = Data(base64Encoded: content, options: .ignoreUnknownCharacters) else {
            throw .unexpected(status: 200, message: "ファイルの中身を読めない（\(file.encoding ?? "encoding なし")）")
        }
        return .file(StoredBlob(data: data, sha: file.sha))
    }

    // MARK: - 要求

    /// Contents API の要求。パスの部品は英数字と ._- だけなので、そのまま URL に入れられる
    private func makeRequest(path: String, query: [URLQueryItem]) async throws(StateStoreError) -> URLRequest {
        try await makeRequest(apiPath: "contents/\(path)", query: query)
    }

    /// リポジトリの API の要求（`apiPath` は `repos/<owner>/<repo>/` からのパス）
    private func makeRequest(apiPath: String, query: [URLQueryItem]) async throws(StateStoreError) -> URLRequest {
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

    private func send(_ request: URLRequest) async throws(StateStoreError) -> (Data, HTTPURLResponse) {
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

enum Contents: Sendable, Equatable {
    case missing
    case file(StoredBlob)
    case directory([DirectoryEntry])
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
            case .missing: 0
            case let .file(blob): blob.data.count
            case let .directory(entries): entries.reduce(0) { $0 + $1.name.utf8.count + $1.path.utf8.count + $1.sha.utf8.count }
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
