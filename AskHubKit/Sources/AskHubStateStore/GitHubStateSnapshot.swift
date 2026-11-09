import Foundation

extension GitHubContentsStore {
    /// 読むだけの、今の状態リポジトリの写し。直下の一覧を ETag つきで 1 回読み（変わっていなければ 304 で、上限に数えられない）、
    /// その下は tree と blob を sha でたどる（`GitHubStateSnapshot`）
    public func snapshot() async throws(StateStoreError) -> any StateStore {
        switch try await get("") {
        case .missing:
            // リポジトリやブランチが見えない。Contents API で読むときと同じく、どのファイルも無いものとする
            return GitHubStateSnapshot(store: self, root: [])
        case let .directory(entries, listed):
            // 状態リポジトリの直下は決まった数件なので、1,000 件で切れていれば決まりと違う
            guard listed < Self.contentsListLimit else {
                throw .unexpected(status: 200, message: "状態リポジトリの直下の一覧が 1,000 件で切れた（決まりでは数件）")
            }
            return GitHubStateSnapshot(store: self, root: entries.map { GitObjectCache.Item(name: $0.name, kind: $0.kind, sha: $0.sha) })
        case .file, .largeFile:
            throw .wrongKind
        }
    }

    /// tree の直下のファイルとディレクトリ。sha で中身が決まるので、前に読んだものがあれば取りに行かない
    func treeItems(sha: String) async throws(StateStoreError) -> [GitObjectCache.Item] {
        guard Self.isObjectSHA(sha) else { throw .unexpected(status: 200, message: "tree の sha の形が違う") }
        if case let .tree(items)? = await objects.object(for: .tree(sha)) { return items }
        let (body, response) = try await send(try await makeRequest(apiPath: "git/trees/\(sha)", query: []))
        guard response.statusCode == 200 else { throw StateStoreError.classify(response, body: body, now: now()) }
        let items = try Self.decodeTree(body, under: "", recursive: false).map { entry in
            GitObjectCache.Item(name: entry.name, kind: entry.kind, sha: entry.sha)
        }
        await objects.store(.tree(items), for: .tree(sha))
        return items
    }

    /// blob の中身。sha で中身が決まるので、前に読んだものがあれば取りに行かない。
    /// 読んだ中身が sha と合わなければ使わない（ほかのファイルの中身と取り違えない）
    func blob(sha: String) async throws(StateStoreError) -> Data {
        guard Self.isObjectSHA(sha) else { throw .unexpected(status: 200, message: "blob の sha の形が違う") }
        if case let .blob(data)? = await objects.object(for: .blob(sha)) { return data }
        var request = try await makeRequest(apiPath: "git/blobs/\(sha)", query: [])
        // base64 の JSON ではなく、中身をそのまま返させる
        request.setValue("application/vnd.github.raw+json", forHTTPHeaderField: "Accept")
        let (body, response) = try await send(request)
        guard response.statusCode == 200 else { throw StateStoreError.classify(response, body: body, now: now()) }
        guard GitBlobSHA.of(body) == sha else { throw .unexpected(status: 200, message: "blob の中身が sha と合わない") }
        await objects.store(.blob(body), for: .blob(sha))
        return body
    }
}

/// 読むだけの、ある時点の状態リポジトリの写し（`GitHubContentsStore.snapshot()`）。
///
/// 写しを作ったときの直下の一覧から、パスの部品ごとに tree をたどって読む。tree と blob は sha で中身が決まるので、前に読んだものは要求を出さずに使い回し、
/// 変わったものだけを取りに行く（1 つのファイルが変われば、そこまでの tree と、そのファイルの blob だけ）。どのパスを読んでも、写しを作ったときの同じコミットの中身になる。
/// 書き込みは断る（書き直すときは、元の置き場所で読み直してから書く）
struct GitHubStateSnapshot: StateStore {
    let store: GitHubContentsStore
    /// リポジトリの直下
    let root: [GitObjectCache.Item]

    func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        guard StatePathCheck.isSafe(path) else { throw .invalidPath }
        guard let item = try await item(at: path) else { return nil }
        guard item.kind == .file else { throw .wrongKind }
        return StoredBlob(data: try await store.blob(sha: item.sha), sha: item.sha)
    }

    /// Git Trees API の tree は件数で切れない（Contents API の 1,000 件の上限が無い）ので、`listAll(_:)` も同じものを返す
    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        guard StatePathCheck.isSafe(directory) else { throw .invalidPath }
        guard let item = try await item(at: directory) else { return nil }
        guard item.kind == .directory else { throw .wrongKind }
        return try await store.treeItems(sha: item.sha).map { child in
            DirectoryEntry(name: child.name, path: "\(directory)/\(child.name)", kind: child.kind, sha: child.sha)
        }
    }

    func listAll(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await list(directory)
    }

    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        throw .unexpected(status: 0, message: "読むだけの写しには書けない（元の置き場所で読み直してから書く）")
    }

    /// 写しの写しではなく、今の中身の写しを作り直す
    func snapshot() async throws(StateStoreError) -> any StateStore {
        try await store.snapshot()
    }

    /// パスの部品を直下からたどった先。無ければ nil（途中がファイルのときも、Contents API と同じく無いものとする）
    private func item(at path: String) async throws(StateStoreError) -> GitObjectCache.Item? {
        var items = root
        var parts = path.split(separator: "/").map(String.init)
        let last = parts.removeLast()
        for name in parts {
            guard let directory = items.first(where: { $0.name == name }), directory.kind == .directory else { return nil }
            items = try await store.treeItems(sha: directory.sha)
        }
        return items.first { $0.name == last }
    }
}

/// sha で中身が決まる Git のオブジェクト（tree の直下と blob）。メモリーにだけ持つ。
///
/// 書き込みのたびに、変わったファイルまでの tree が新しくなり、古いものは使われなくなる。持ちすぎないよう、2 つの世代に分けて持ち、
/// 今の世代がいっぱいになったら前の世代を捨てる。前の世代から読んだものは今の世代に移すので、続けて使うもの（終わった epic など）は捨てられない
actor GitObjectCache {
    struct Item: Sendable, Equatable {
        var name: String
        var kind: DirectoryEntry.Kind
        var sha: String
    }

    enum Key: Hashable {
        case tree(String)
        case blob(String)
    }

    enum Object: Sendable, Equatable {
        case tree([Item])
        case blob(Data)

        /// 持っている中身の大きさの目安
        var size: Int {
            switch self {
            case let .tree(items): items.reduce(0) { $0 + $1.name.utf8.count + $1.sha.utf8.count + 16 }
            case let .blob(data): data.count
            }
        }
    }

    /// 1 つの世代に持つ数と大きさの上限（既定は、状態リポジトリのファイルの数と大きさより十分に大きい。2 つの世代で、この倍まで持つ）
    let generationCount: Int
    let generationSize: Int
    private var current: [Key: Object] = [:]
    private var currentSize = 0
    private var previous: [Key: Object] = [:]

    init(generationCount: Int = 10_000, generationSize: Int = 32 * 1_024 * 1_024) {
        self.generationCount = generationCount
        self.generationSize = generationSize
    }

    func object(for key: Key) -> Object? {
        if let object = current[key] { return object }
        guard let object = previous.removeValue(forKey: key) else { return nil }
        store(object, for: key)
        return object
    }

    func store(_ object: Object, for key: Key) {
        // 1 つで上限を超えるものは持たない
        guard current[key] == nil, object.size <= generationSize else { return }
        if current.count >= generationCount || currentSize + object.size > generationSize {
            previous = current
            current = [:]
            currentSize = 0
        }
        current[key] = object
        currentSize += object.size
    }
}
