import Foundation

/// sha で中身が決まる Git のオブジェクト（tree の直下と blob）を、端末のファイルにも持つ（`GitObjectCache` の後ろ）。
///
/// メモリーの持ち物は起動し直すと消えるので、起動の直後も、変わっていない tree と blob を GitHub から読み直さないよう、ファイルにも持つ
/// （GitHub から読むと 200 で上限に数えられる。アプリは起動のたびに状態リポジトリの全体を読む）。
/// 持ちすぎないよう、メモリーと同じく 2 つの世代（ディレクトリ）に分け、今の世代がいっぱいになったら前の世代を消す。
/// 前の世代から読んだものは今の世代に移す（起動のたびに、使っているものはファイルから読み直すので、使い続けるものは消えにくい）。
/// 読めないファイル・中身が sha と合わない blob は使わずに消し、GitHub から読み直させる。ファイルを読み書きできなくても、メモリーだけで動く
struct GitObjectDiskStore {
    let directory: URL
    let generationCount: Int
    let generationSize: Int
    /// 今の世代のファイルの数と大きさ。初めて書くときに数える
    private var counted: (count: Int, size: Int)?

    init(directory: URL, generationCount: Int, generationSize: Int) {
        self.directory = directory
        self.generationCount = generationCount
        self.generationSize = generationSize
    }

    private var current: URL { directory.appending(path: "current", directoryHint: .isDirectory) }
    private var previous: URL { directory.appending(path: "previous", directoryHint: .isDirectory) }

    /// 持っているもの。前の世代にあれば、今の世代に移す
    mutating func object(for key: GitObjectCache.Key) -> GitObjectCache.Object? {
        let name = Self.fileName(for: key)
        let fileManager = FileManager.default
        let inCurrent = current.appending(path: name)
        if let data = try? Data(contentsOf: inCurrent) {
            guard let object = Self.decode(data, for: key) else {
                try? fileManager.removeItem(at: inCurrent)
                counted = nil
                return nil
            }
            return object
        }
        let inPrevious = previous.appending(path: name)
        guard let data = try? Data(contentsOf: inPrevious) else { return nil }
        guard let object = Self.decode(data, for: key) else {
            try? fileManager.removeItem(at: inPrevious)
            return nil
        }
        // 移せなければ（今の世代がいっぱいで世代を替え、前の世代ごと消したときなど）、今の世代に書き直す
        if reserve(data.count), (try? fileManager.moveItem(at: inPrevious, to: inCurrent)) != nil {
            added(data.count)
        } else {
            store(object, for: key)
        }
        return object
    }

    /// 持つ。1 つで世代の上限を超えるものは持たない
    mutating func store(_ object: GitObjectCache.Object, for key: GitObjectCache.Key) {
        guard let data = Self.encode(object), data.count <= generationSize else { return }
        let url = current.appending(path: Self.fileName(for: key))
        guard !FileManager.default.fileExists(atPath: url.path), reserve(data.count) else { return }
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        added(data.count)
    }

    /// 今の世代に `size` を足せるようにする（いっぱいなら世代を替える）。今の世代のディレクトリを作れなければ false
    private mutating func reserve(_ size: Int) -> Bool {
        let fileManager = FileManager.default
        let now = counted ?? count()
        if now.count >= generationCount || now.size + size > generationSize {
            try? fileManager.removeItem(at: previous)
            try? fileManager.moveItem(at: current, to: previous)
            // 移せなかったものは、前の世代の代わりに消す（持ちすぎない）
            try? fileManager.removeItem(at: current)
            counted = (0, 0)
        } else {
            counted = now
        }
        do {
            try fileManager.createDirectory(at: current, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    private mutating func added(_ size: Int) {
        let now = counted ?? (0, 0)
        counted = (now.count + 1, now.size + size)
    }

    /// 今の世代のファイルの数と大きさ
    private func count() -> (count: Int, size: Int) {
        let files = (try? FileManager.default.contentsOfDirectory(at: current, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let size = files.reduce(0) { total, url in total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return (files.count, size)
    }

    /// sha は 16 進の小文字だけ（`GitHubContentsStore.isObjectSHA` を通したもの）なので、そのままファイル名にできる
    static func fileName(for key: GitObjectCache.Key) -> String {
        switch key {
        case let .tree(sha): "tree-\(sha).json"
        case let .blob(sha): "blob-\(sha)"
        }
    }

    /// tree の直下の 1 つ（ファイルに書く形）
    private struct StoredItem: Codable {
        var name: String
        var kind: String
        var sha: String
    }

    static func encode(_ object: GitObjectCache.Object) -> Data? {
        switch object {
        case let .blob(data):
            data

        case let .tree(items):
            try? JSONEncoder().encode(items.map { StoredItem(name: $0.name, kind: $0.kind.rawValue, sha: $0.sha) })
        }
    }

    /// 読んだファイルの中身。blob は中身から求めた sha が合うものだけを使う（ほかのファイルの中身や、壊れた中身と取り違えない）
    static func decode(_ data: Data, for key: GitObjectCache.Key) -> GitObjectCache.Object? {
        switch key {
        case let .blob(sha):
            return GitBlobSHA.of(data) == sha ? .blob(data) : nil

        case .tree:
            guard let stored = try? JSONDecoder().decode([StoredItem].self, from: data) else { return nil }
            var items: [GitObjectCache.Item] = []
            for item in stored {
                guard let kind = DirectoryEntry.Kind(rawValue: item.kind), GitHubContentsStore.isObjectSHA(item.sha) else { return nil }
                items.append(GitObjectCache.Item(name: item.name, kind: kind, sha: item.sha))
            }
            return .tree(items)
        }
    }
}
