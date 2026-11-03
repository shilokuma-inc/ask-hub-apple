import AskHubProtocol
import Foundation

/// 待つ部品。テストでは待たずに記録するものに差し替える
public protocol Sleeper: Sendable {
    func sleep(for duration: Duration) async throws
}

public struct TaskSleeper: Sleeper {
    public init() {}

    public func sleep(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
    }
}

/// 状態リポジトリのファイルを、型（`StateFile`）で読み書きする。
///
/// - 読めないファイル（知らない版・形の違うもの）は、上書きしない。読めない理由を返して止まる
/// - 書き直しは「読む → 変える → 読んだときの版を付けて書く」で行い、ぶつかったら間を空けて読み直す
/// - 404 を理由にファイルを作り直さない。作るのは `create` と `replace` だけで、どちらもすでにあるファイルを版なしで上書きできない
///   （Contents API は、版を付けない書き込みを、ファイルがあれば断る）
public struct StateFileStore: Sendable {
    public struct Loaded<File: StateFile>: Sendable {
        public var file: File
        /// 読んだとき（または書いた後）の版
        public var sha: String
    }

    public enum Failure: Error, Equatable, Sendable {
        case store(StateStoreError)
        /// ファイルが読めない。上書きせずに知らせる
        case unreadable(path: String, StateFileError)
        /// 作ろうとしたファイルが、すでにある
        case alreadyExists
        /// 書き直そうとしたファイルが無い
        case notFound
        /// ほかの書き手とぶつかり続け、決めた回数でやめた
        case tooManyConflicts
        /// 書くファイルが型の決まりに合わない
        case invalidFile(String)
    }

    public let store: any StateStore
    public let sleeper: any Sleeper
    /// ぶつかったときに試す回数（最初の 1 回を含む）
    public var maxAttempts = 4

    public init(store: any StateStore, sleeper: any Sleeper = TaskSleeper()) {
        self.store = store
        self.sleeper = sleeper
    }

    /// 読む。無ければ nil
    public func read<File: StateFile>(_ type: File.Type, at path: String) async throws(Failure) -> Loaded<File>? {
        let blob: StoredBlob?
        do {
            blob = try await store.read(path)
        } catch {
            throw .store(error)
        }
        guard let blob else { return nil }
        do {
            return try Loaded(file: StateFileCoder.decode(File.self, from: blob.data), sha: blob.sha)
        } catch {
            throw .unreadable(path: path, error)
        }
    }

    /// 新しく作る。すでにあれば `alreadyExists`（ほかの書き手が先に作った）
    @discardableResult
    public func create<File: StateFile>(_ file: File, at path: String, message: String) async throws(Failure) -> Loaded<File> {
        let data = try Self.encode(file)
        do {
            return try await Loaded(file: file, sha: store.write(path, data: data, replacing: nil, message: message))
        } catch .conflict {
            throw .alreadyExists
        } catch {
            throw .store(error)
        }
    }

    /// 自分だけが書くファイル（生きている印など）を、今の中身にかかわらず置き換える。無ければ作る
    @discardableResult
    public func replace<File: StateFile>(_ file: File, at path: String, message: String) async throws(Failure) -> Loaded<File> {
        let data = try Self.encode(file)
        return try await retryingConflicts { () async throws(Failure) -> Loaded<File> in
            let current: StoredBlob?
            do throws(StateStoreError) {
                current = try await store.read(path)
            } catch {
                throw .store(error)
            }
            do throws(StateStoreError) {
                return try await Loaded(file: file, sha: store.write(path, data: data, replacing: current?.sha, message: message))
            } catch {
                throw .store(error)
            }
        }
    }

    /// 書き直す。`change` は今の中身を受け取って変え、書く必要があれば `true` を返す（`false` なら書かずに今の中身を返す）。
    /// ぶつかったら読み直して、もう一度 `change` から行う
    @discardableResult
    public func update<File: StateFile>(
        _ type: File.Type,
        at path: String,
        message: String,
        _ change: (inout File) -> Bool
    ) async throws(Failure) -> Loaded<File> {
        try await retryingConflicts { () async throws(Failure) -> Loaded<File> in
            guard var loaded = try await read(File.self, at: path) else { throw .notFound }
            guard change(&loaded.file) else { return loaded }
            let data = try Self.encode(loaded.file)
            do throws(StateStoreError) {
                loaded.sha = try await store.write(path, data: data, replacing: loaded.sha, message: message)
            } catch {
                throw .store(error)
            }
            return loaded
        }
    }

    // MARK: -

    private static func encode<File: StateFile>(_ file: File) throws(Failure) -> Data {
        do {
            return try StateFileCoder.encode(file)
        } catch let error as StateFileError {
            throw .invalidFile("\(error)")
        } catch {
            throw .invalidFile(String(describing: type(of: error)))
        }
    }

    /// `conflict` のときだけ、間を空けてやり直す（1 秒・2 秒・4 秒…に 0〜1 秒のずれを足す。書き手どうしが同じ間隔でぶつかり続けないように）
    private func retryingConflicts<Result>(_ body: () async throws(Failure) -> Result) async throws(Failure) -> Result {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch .store(.conflict) where attempt < maxAttempts {
                let wait = Duration.seconds(1 << (attempt - 1)) + .milliseconds(Int.random(in: 0..<1_000))
                do {
                    try await sleeper.sleep(for: wait)
                } catch {
                    throw .store(.cancelled)
                }
                attempt += 1
            } catch .store(.conflict) {
                throw .tooManyConflicts
            }
        }
    }
}
