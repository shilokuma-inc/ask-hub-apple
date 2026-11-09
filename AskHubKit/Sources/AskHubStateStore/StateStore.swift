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

    /// ディレクトリの下のファイルを、下の階層まですべて並べる（`path` は状態リポジトリの直下からのパス）。ディレクトリが無ければ nil。
    /// 人の意図のように増え続けるディレクトリに使う
    func listFiles(under directory: String) async throws(StateStoreError) -> [DirectoryEntry]?

    /// ディレクトリの直下を、件数で切らずにすべて並べる（下の階層は辿らない）。ディレクトリが無ければ nil。
    /// epic やジョブのように増え続け、下の階層まで読むと大きすぎるディレクトリに使う
    func listAll(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]?

    /// 読むだけの、今の中身の写し。1 回の処理で多くのファイルを読むとき（司令塔のジョブの見回りなど）に使う。
    ///
    /// 写しから読むと、写しを作ったときの中身になる（GitHub では同じコミットの中身。前に読んだ tree と blob を使い回し、変わったものだけを取りに行く）。
    /// 写しには書かない。書き直すときは、元の置き場所で読み直してから書く
    func snapshot() async throws(StateStoreError) -> any StateStore
}

extension StateStore {
    /// `list` を下の階層まで辿る。1 つのディレクトリの一覧に上限の無い置き場所（メモリ上など）で使う
    public func listFiles(under directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        guard let entries = try await list(directory) else { return nil }
        var files: [DirectoryEntry] = []
        for entry in entries {
            switch entry.kind {
            case .file: files.append(entry)
            case .directory: files += try await listFiles(under: entry.path) ?? []
            }
        }
        return files
    }

    /// `list` をそのまま使う。1 つのディレクトリの一覧に上限の無い置き場所（メモリ上など）で使う
    public func listAll(_ directory: String) async throws(StateStoreError) -> [DirectoryEntry]? {
        try await list(directory)
    }

    /// 自分をそのまま返す（読むたびに今の中身を読む）。写しを作るまでもない置き場所（テスト用のものなど）で使う
    public func snapshot() async throws(StateStoreError) -> any StateStore {
        self
    }
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
