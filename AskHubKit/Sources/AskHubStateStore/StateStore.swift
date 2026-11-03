import Foundation

/// 状態リポジトリの 1 つのファイルの中身と版
public struct StoredBlob: Sendable, Equatable {
    public var data: Data
    /// Git の blob の sha。書き込むときに「読んだときの版」として渡す
    public var sha: String

    public init(data: Data, sha: String) {
        self.data = data
        self.sha = sha
    }
}

/// ディレクトリの中の 1 つ
public struct DirectoryEntry: Sendable, Equatable {
    public enum Kind: String, Sendable {
        case file
        case directory = "dir"
    }

    public var name: String
    public var path: String
    public var kind: Kind
    public var sha: String

    public init(name: String, path: String, kind: Kind, sha: String) {
        self.name = name
        self.path = path
        self.kind = kind
        self.sha = sha
    }
}

/// 状態リポジトリの読み書き（`docs/renewal/protocol.md` の「共通の決まり」）。パスは状態リポジトリの中の相対パス（`StatePath`）
public protocol StateStore: Sendable {
    /// ファイルを読む。無ければ nil（GitHub は、リポジトリやブランチが見えないときも同じ 404 を返すので、そのときも nil）
    func read(_ path: String) async throws(StateStoreError) -> StoredBlob?

    /// ディレクトリの中を並べる。無ければ nil。
    ///
    /// GitHub の障害のときは、中身があっても空の一覧が返ることがある。空の一覧を理由に、ファイルを作り直さない
    func list(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]?

    /// ファイルを書く。`replacing` は読んだときの版で、nil なら新しく作る（すでにあれば `conflict`）。書いた後の版を返す
    func write(_ path: String, data: Data, replacing sha: String?, message: String) async throws(StateStoreError) -> String
}

enum StatePathCheck {
    /// 英数字と `._-` の部品を `/` でつないだ相対パスか。`.`・`..`・空の部品を受け付けない
    static func isSafe(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !parts.isEmpty && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".."
                && part.utf8.allSatisfy { byte in
                    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                        || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                        || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
                }
        }
    }
}
