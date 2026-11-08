import AskHubProtocol
import Foundation

/// epic ごとの DerivedData と結果のバンドルの置き場所（ワーカー専用のフォルダの下）。
///
/// `<root>/<epic>/DerivedData` と `<root>/<epic>/results/<名前>.xcresult`。並んで動く epic の DerivedData を分け
/// （同じ DerivedData を共有するとビルドが壊れる）、epic が終わったら epic ごと消す（`docs/renewal/operations.md` の「容量」）
public struct BuildDirectories: Sendable {
    public var root: URL

    public init(root: URL) {
        self.root = root
    }

    public func epicDirectory(_ epic: ULID) -> URL {
        root.appendingPathComponent(epic.rawValue, isDirectory: true)
    }

    public func derivedData(for epic: ULID) -> URL {
        epicDirectory(epic).appendingPathComponent("DerivedData", isDirectory: true)
    }

    /// 結果のバンドル。`name` の英数字と `.`・`-` のほかは `-` にする
    public func resultBundle(for epic: ULID, named name: String) -> URL {
        let name = SimulatorPool.slug(name)
        return epicDirectory(epic).appendingPathComponent("results/\(name.isEmpty ? "result" : name).xcresult", isDirectory: true)
    }

    /// epic の DerivedData と結果のバンドルを消す（最終 PR のマージの後など）。無ければ何もしない
    public func remove(_ epic: ULID) throws(BuildDirectoryError) {
        try Self.remove(epicDirectory(epic))
    }

    /// 置き場所がある epic。epic の形（ULID）でない名前のものは除く
    public func epics() -> [ULID] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.sorted().compactMap(ULID.init(rawValue:))
    }

    /// `active` に無い epic の置き場所を消し、消した epic を返す。epic の形（ULID）でない名前のものには触れない
    public func removeEpics(except active: Set<ULID>) throws(BuildDirectoryError) -> [ULID] {
        var removed: [ULID] = []
        for epic in epics() where !active.contains(epic) {
            try remove(epic)
            removed.append(epic)
        }
        return removed
    }

    /// 前の結果のバンドルを消し、置き場所のフォルダを作る（`xcodebuild` は、すでにある結果のバンドルには書かない）
    func prepareResultBundle(at bundle: URL) throws(BuildDirectoryError) {
        try Self.remove(bundle)
        do {
            try FileManager.default.createDirectory(at: bundle.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw BuildDirectoryError("\(bundle.deletingLastPathComponent().lastPathComponent) を作れない（\(error.localizedDescription)）")
        }
    }

    private static func remove(_ url: URL) throws(BuildDirectoryError) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw BuildDirectoryError("\(url.lastPathComponent) を消せない（\(error.localizedDescription)）")
        }
    }
}

/// 置き場所を作れない・消せない
public struct BuildDirectoryError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var description: String { message }
}
