import Foundation

/// 同時に動かす数を `limit` までにする。空きを待つものは、待ち始めた順に動かす
public actor ConcurrencyLimit {
    public let limit: Int
    private var running = 0
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(_ limit: Int) {
        self.limit = max(limit, 1)
    }

    /// 空きを 1 つ借りる。空くまで待つ。待つ間に取り消されたら `CancellationError` を投げる（借りていない）
    public func acquire() async throws {
        guard running >= limit else {
            running += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await wait(id)
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }

    private func wait(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            // 取り消された後に待ち始めたなら、待たずに終える（取り消しの知らせが、並ぶ前に届いていることがある）
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
            } else {
                waiters.append((id, continuation))
            }
        }
    }

    /// 借りた空きを返す。待つものがあれば、空きをそのまま渡す
    public func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// 状態リポジトリへの同時の要求を `limit` までにする（GitHub の 2 次のレート制限に当たらないように）。
///
/// 読む側がいくつ並べても、下の置き場所に同時に出る要求はこの数を超えない。1 つの呼び出しが下で複数の要求を順に出す（`listAll` など）ときも、
/// 空きは 1 つだけ借りる。上限で 403・429 が返ったときの扱い（`StateStoreError.rateLimited`）は、下の置き場所のまま
public struct ConcurrencyLimitedStore: StateStore {
    public let base: any StateStore
    private let limit: ConcurrencyLimit

    public init(_ base: any StateStore, limit: Int) {
        self.base = base
        self.limit = ConcurrencyLimit(limit)
    }

    public func read(_ path: String) async throws(StateStoreError) -> StoredBlob? {
        try await limited { () throws(StateStoreError) in try await base.read(path) }
    }

    public func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await limited { () throws(StateStoreError) in try await base.list(directory) }
    }

    public func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String {
        try await limited { () throws(StateStoreError) in try await base.write(path, data: data, replacing: sha, message: message) }
    }

    public func listFiles(under directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await limited { () throws(StateStoreError) in try await base.listFiles(under: directory) }
    }

    public func listAll(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await limited { () throws(StateStoreError) in try await base.listAll(directory) }
    }

    private func limited<Value>(_ body: () async throws(StateStoreError) -> Value) async throws(StateStoreError) -> Value {
        do {
            try await limit.acquire()
        } catch {
            throw .cancelled
        }
        let result: Result<Value, StateStoreError>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }
        await limit.release()
        return try result.get()
    }
}
