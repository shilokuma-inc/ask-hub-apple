import AskHubProtocol
import Foundation

/// GitHub の Contents API で状態リポジトリを読み書きする。
///
/// - 読み取りは ETag を付ける。変わっていなければ 304 が返り、上限に数えられない
/// - 書き込みは読んだときの版（sha）を付ける。版が合わない・同じブランチへの書き込みがぶつかったときは 409 が返る
///   （Contents API は同じブランチへの並んだ書き込みもぶつかる）ので、`StateFileStore` が読み直してやり直す
/// - ディレクトリの一覧は 1,000 件まで（Contents API の上限）。状態リポジトリのディレクトリはそれより小さく保つ
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
        switch try await get(path) {
        case .missing: return nil
        case let .file(blob): return blob
        case .directory: throw .wrongKind
        }
    }

    public func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        switch try await get(directory) {
        case .missing: return nil
        case let .directory(entries): return entries
        case .file: throw .wrongKind
        }
    }

    public func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        guard StatePathCheck.isSafe(path) else { throw .invalidPath }
        try await budget?.reserve(now: now())
        let body = WriteBody(message: message, content: data.base64EncodedString(), sha: sha, branch: branch)
        var request = try await makeRequest(path: path, query: [])
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

    private func get(_ path: String) async throws(StateStoreError) -> Contents {
        guard StatePathCheck.isSafe(path) else { throw .invalidPath }
        var request = try await makeRequest(path: path, query: branch.map { [URLQueryItem(name: "ref", value: $0)] } ?? [])
        let cached = await cache.entry(for: path)
        if let cached { request.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
        let (body, response) = try await send(request)
        switch response.statusCode {
        case 304:
            guard let cached else { throw .unexpected(status: 304, message: "ETag を付けていないのに 304 が返った") }
            return cached.contents
        case 404:
            await cache.remove(path)
            return .missing
        case 200:
            let contents = try Self.decodeContents(body)
            if let etag = response.value(forHTTPHeaderField: "ETag") {
                await cache.store(path, ETagCache.Entry(etag: etag, contents: contents))
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

    private func makeRequest(path: String, query: [URLQueryItem]) async throws(StateStoreError) -> URLRequest {
        // パスの部品は英数字と ._- だけなので、そのまま URL に入れられる
        var components = URLComponents(
            url: apiBase.appendingPathComponent("repos/\(repository.owner)/\(repository.name)/contents/\(path)"),
            resolvingAgainstBaseURL: false
        )
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url else { throw .invalidPath }
        let token: String
        do {
            token = try await self.token()
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
    }

    /// 持ちすぎないよう、この数を超えたら空にする（状態リポジトリのファイルの数より十分に大きい）
    static let limit = 5_000
    private var entries: [String: Entry] = [:]

    func entry(for path: String) -> Entry? { entries[path] }

    func store(_ path: String, _ entry: Entry) {
        if entries.count >= Self.limit { entries.removeAll() }
        entries[path] = entry
    }

    func remove(_ path: String) { entries[path] = nil }
}
