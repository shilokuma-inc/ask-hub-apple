import AskHubProtocol
import Foundation

/// 対象のリポジトリの tree から、アプリのアイコンの元を選ぶ（`docs/renewal/architecture.md` の「対象のアプリのアイコン」）
public enum AppIconLocator {
    /// アイコンの元のフォルダ（Icon Composer の `.icon` か、Asset Catalog の `.appiconset`）
    public struct Source: Equatable, Sendable {
        /// リポジトリの直下からのパス
        public var path: String
        /// フォルダの git の tree の sha
        public var tree: String

        public init(path: String, tree: String) {
            self.path = path
            self.tree = tree
        }
    }

    /// 元のフォルダの中の 1 つのファイル
    struct Blob: Equatable, Sendable {
        /// 元のフォルダからのパス
        var path: String
        var sha: String
        var size: Int
    }

    /// 見ないフォルダ（依存・ビルドの残り・プレビュー用）。テストのフォルダ（名前が `Tests` で終わる）も見ない
    static let ignoredDirectories: Set<String> = ["Pods", "Carthage", ".build", "DerivedData", "node_modules", "Preview Content"]

    /// `git ls-tree -r -d -z <コミット>`（tree だけを下の階層まで）の出力から選ぶ
    static func choose(fromTreeListing listing: String) -> Source? {
        let trees = records(in: listing).compactMap { record -> Source? in
            guard record.type == "tree" else { return nil }
            return Source(path: record.path, tree: record.sha)
        }
        return choose(trees)
    }

    /// `AppIcon.icon`・`AppIcon.appiconset`・ほかの `.icon`・ほかの `.appiconset` の順に選ぶ。同じ順なら浅いもの、同じ深さならパスの順
    static func choose(_ trees: [Source]) -> Source? {
        let candidates = trees.compactMap { tree -> Candidate? in
            let parts = tree.path.split(separator: "/").map(String.init)
            guard let name = parts.last, let rank = rank(of: name),
                  !parts.dropLast().contains(where: { ignoredDirectories.contains($0) || $0.hasSuffix("Tests") }) else { return nil }
            return Candidate(rank: rank, depth: parts.count, source: tree)
        }
        return candidates.min { ($0.rank, $0.depth, $0.source.path) < ($1.rank, $1.depth, $1.source.path) }?.source
    }

    private struct Candidate {
        var rank: Int
        var depth: Int
        var source: Source
    }

    private static func rank(of name: String) -> Int? {
        switch name {
        case "AppIcon.icon": 0
        case "AppIcon.appiconset": 1
        case _ where name.hasSuffix(".icon"): 2
        case _ where name.hasSuffix(".appiconset"): 3
        default: nil
        }
    }

    /// `git ls-tree -r -l -z <tree>`（ファイルを下の階層まで、大きさつき）の出力のファイル。シンボリックリンクとサブモジュールは除く。
    /// 取り出す先の外を指すパス（`..` など）があれば、読めないものとして nil
    static func blobs(fromListing listing: String) -> [Blob]? {
        var blobs: [Blob] = []
        for record in records(in: listing) {
            guard record.type == "blob", ["100644", "100755"].contains(record.mode) else { continue }
            guard isSafeRelativePath(record.path), let size = record.size else { return nil }
            blobs.append(Blob(path: record.path, sha: record.sha, size: size))
        }
        return blobs
    }

    /// 空・`.`・`..` の部品を含まない相対パスか
    static func isSafeRelativePath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.utf8.count <= 1_000 && !path.contains("\0")
            && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    // MARK: - ls-tree の出力

    private struct Record {
        var mode: String
        var type: String
        var sha: String
        /// `-l` のときの大きさ（tree は `-`）
        var size: Int?
        var path: String
    }

    /// `-z` の出力（`<mode> <type> <sha>[ <size>]<TAB><path>` を NUL で区切ったもの）
    private static func records(in listing: String) -> [Record] {
        listing.split(separator: "\0").compactMap { line in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let fields = line[..<tab].split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard fields.count == 3 || fields.count == 4, AttemptFile.isCommitSHA(fields[2]) else { return nil }
            return Record(
                mode: fields[0],
                type: fields[1],
                sha: fields[2],
                size: fields.count == 4 ? Int(fields[3]) : nil,
                path: String(line[line.index(after: tab)...])
            )
        }
    }
}
