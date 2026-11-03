import CryptoKit
import Foundation

/// メモリーの中の状態リポジトリ。テストと、GitHub に書かずに試す実行で使う。
///
/// Contents API と同じく、版が合わない書き込み・すでにあるファイルを版なしで書く書き込みを `conflict` で断る
public actor InMemoryStateStore: StateStore {
    private var files: [String: StoredBlob] = [:]
    /// 書き込みの前に投げる失敗（テストで、ほかの書き手とぶつかったときなどを再現する）
    private var injectedWriteFailures: [StateStoreError] = []
    /// 次の書き込みの直前に、ほかの書き手が書いたことにする中身
    private var interleavedWrites: [(path: String, data: Data)] = []
    public private(set) var writeCount = 0

    public init(files: [String: Data] = [:]) {
        self.files = files.mapValues { StoredBlob(data: $0, sha: Self.sha(of: $0)) }
    }

    public func read(_ path: String) throws(StateStoreError) -> StoredBlob? {
        guard StatePathCheck.isSafe(path) else { throw .invalidPath }
        if files.keys.contains(where: { $0.hasPrefix(path + "/") }) { throw .wrongKind }
        return files[path]
    }

    public func list(_ directory: String) throws(StateStoreError) -> [DirectoryEntry]? {
        guard StatePathCheck.isSafe(directory) else { throw .invalidPath }
        if files[directory] != nil { throw .wrongKind }
        let prefix = directory + "/"
        var entries: [String: DirectoryEntry] = [:]
        for (path, blob) in files where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            let name = String(rest.prefix { $0 != "/" })
            let isFile = !rest.contains("/")
            entries[name] = DirectoryEntry(
                name: name,
                path: prefix + name,
                kind: isFile ? .file : .directory,
                sha: isFile ? blob.sha : ""
            )
        }
        return entries.isEmpty ? nil : entries.values.sorted { $0.name < $1.name }
    }

    public func write(_ path: String, data: Data, replacing sha: String?, message: String) throws(StateStoreError) -> String {
        guard StatePathCheck.isSafe(path) else { throw .invalidPath }
        if !injectedWriteFailures.isEmpty { throw injectedWriteFailures.removeFirst() }
        if !interleavedWrites.isEmpty {
            let other = interleavedWrites.removeFirst()
            put(other.path, data: other.data)
        }
        guard files[path]?.sha == sha else { throw .conflict }
        let blob = StoredBlob(data: data, sha: Self.sha(of: data))
        files[path] = blob
        writeCount += 1
        return blob.sha
    }

    /// 次の書き込みで、順に投げる失敗を足す
    public func failNextWrites(with failures: [StateStoreError]) {
        injectedWriteFailures += failures
    }

    /// 次の書き込みの直前に、ほかの書き手が書いたことにする（読んだ後に書き換えられた状態を再現する）
    public func writeBeforeNextWrite(_ path: String, data: Data) {
        interleavedWrites.append((path, data))
    }

    /// ほかの書き手が書いたことにする
    public func put(_ path: String, data: Data) {
        files[path] = StoredBlob(data: data, sha: Self.sha(of: data))
    }

    public func data(at path: String) -> Data? {
        files[path]?.data
    }

    /// Git の blob の sha と同じ求め方（`blob <長さ>\0` を前に付けた SHA-1）
    static func sha(of data: Data) -> String {
        var hasher = Insecure.SHA1()
        hasher.update(data: Data("blob \(data.count)\0".utf8))
        hasher.update(data: data)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
