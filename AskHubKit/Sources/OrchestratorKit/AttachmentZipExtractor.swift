import AskHubKit
import Foundation

/// zip の添付を、検査してから展開する（`docs/protocol.md` の「zip の展開」・Discussion #761 の Q2）。
///
/// `zipinfo` / `unzip` は使わず、中央ディレクトリを自前で読み（`AttachmentZipArchive`）、展開する項目だけを書く（`AttachmentZipWriter`）。
/// 危険な項目（`..`・絶対パス・シンボリックリンクなど）はディスクに書く前に弾き、展開した後にも展開先の外を指すものが無いかを確かめる。
/// 中身は依頼と同じくデータで、ここでは読ませ方を決めない（使う側がプロンプトにデータとして渡す）
public struct AttachmentZipExtractor: Sendable {
    /// 展開後の合計の上限
    public struct Limits: Sendable, Equatable {
        /// 展開後の大きさの合計（既定 100 MB。1 MB = 1,048,576 バイト）
        public var maxTotalBytes: Int
        /// 展開するファイルの数（既定 500。ディレクトリと展開しなかった項目は数えない）
        public var maxFileCount: Int
        /// 作るディレクトリの数（既定 1,000。仮決め）。ディレクトリの項目と、ファイルの親のディレクトリを重ねずに数える
        public var maxDirectoryCount: Int

        public init(maxTotalBytes: Int = 100 * 1_024 * 1_024, maxFileCount: Int = 500, maxDirectoryCount: Int = 1_000) {
            self.maxTotalBytes = maxTotalBytes
            self.maxFileCount = maxFileCount
            self.maxDirectoryCount = maxDirectoryCount
        }

        public static let `default` = Self()
    }

    public let limits: Limits

    public init(limits: Limits = .default) {
        self.limits = limits
    }

    /// `archive` を `destination` に展開する。`destination` は先に消して作り直す（前の試行の残りを読ませない）。
    /// `destination` はリポジトリの checkout・制御用 worktree・スロットの外（添付のキャッシュの下）にする。
    /// zip 全体を展開できなければ、`destination` を消して投げる
    public func extract(zipAt archive: URL, to destination: URL) throws(AttachmentZipError) -> AttachmentZipContents {
        let root = Self.trimmingTrailingSlashes(destination.standardizedFileURL.path(percentEncoded: false))
        let archivePath = archive.standardizedFileURL.path(percentEncoded: false)
        // 展開先そのものか、その下に zip があると、展開の前に消すときに zip も消えてしまう
        let realRoot = Self.realPath(root) ?? root
        if Self.isSameOrInside(archivePath, root) || Self.realPath(archivePath).map({ Self.isSameOrInside($0, realRoot) }) == true {
            throw .destinationContainsArchive
        }
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: root)
        guard !fileManager.fileExists(atPath: root) else {
            throw .cannotWrite(reason: "前の展開先を消せませんでした")
        }
        do {
            return try extract(archive, into: root)
        } catch {
            try? fileManager.removeItem(atPath: root)
            throw error
        }
    }

    private struct PlannedEntry {
        let index: Int
        let entry: AttachmentZipArchive.Entry
        let components: [String]
        let isDirectory: Bool
    }

    /// 書いたファイル
    private struct WrittenFile {
        let entryPath: String
        let path: String
        let size: Int
    }

    private typealias IndexedSkip = (index: Int, entry: AttachmentZipContents.SkippedEntry)

    private func extract(_ archive: URL, into root: String) throws(AttachmentZipError) -> AttachmentZipContents {
        let data: Data
        do {
            data = try Data(contentsOf: archive)
        } catch {
            throw .unreadable(reason: error.localizedDescription)
        }
        let zip = try AttachmentZipArchive(data: data)
        let (planned, skippedByRule) = Self.plan(zip)
        // 展開する前に、中央ディレクトリの宣言値で上限を確かめる（超えていれば何も書かない）
        try checkDeclaredLimits(planned)
        let (written, conflicts) = try write(planned, from: zip, into: root)
        // 宣言値は偽れるので、書いた後にも展開先を数え直し、展開先の外を指すものが無いことを確かめる
        try Self.verify(root: root, limits: limits)

        var readableFiles: [AttachmentZipContents.ReadableFile] = []
        var materials: [AttachmentZipContents.Material] = []
        for file in written {
            if let type = Self.readableType(of: file.path) {
                readableFiles.append(.init(path: file.path, entryPath: file.entryPath, type: type, size: file.size))
            } else {
                materials.append(.init(path: file.path, entryPath: file.entryPath, size: file.size))
            }
        }
        return AttachmentZipContents(
            directory: root,
            readableFiles: readableFiles,
            materials: materials,
            skippedEntries: (skippedByRule + conflicts).sorted { $0.index < $1.index }.map(\.entry)
        )
    }

    /// 項目ごとに、展開するか（どこに）・飛ばすか（理由）を決める
    private static func plan(_ zip: AttachmentZipArchive) -> (planned: [PlannedEntry], skipped: [IndexedSkip]) {
        var planned: [PlannedEntry] = []
        var skipped: [IndexedSkip] = []
        for (index, entry) in zip.entries.enumerated() {
            switch AttachmentZipEntryRule.plan(for: entry) {
            case let .directory(components):
                planned.append(PlannedEntry(index: index, entry: entry, components: components, isDirectory: true))

            case let .file(components):
                planned.append(PlannedEntry(index: index, entry: entry, components: components, isDirectory: false))

            case let .skip(reason):
                skipped.append((index, skippedEntry(entry, reason: reason)))
            }
        }
        return (planned, skipped)
    }

    private func checkDeclaredLimits(_ planned: [PlannedEntry]) throws(AttachmentZipError) {
        let files = planned.filter { !$0.isDirectory }
        guard files.count <= limits.maxFileCount else {
            throw .tooManyFiles(count: files.count, limit: limits.maxFileCount)
        }
        // ZIP64 の宣言値は大きくできるので、あふれたら最大の値として比べる
        let declared = files.reduce(0) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.entry.uncompressedSize)
            return overflow ? Int.max : sum
        }
        guard declared <= limits.maxTotalBytes else {
            throw .declaredTooLarge(bytes: declared, limit: limits.maxTotalBytes)
        }
        let directories = Self.directoryCount(of: planned)
        guard directories <= limits.maxDirectoryCount else {
            throw .tooManyDirectories(count: directories, limit: limits.maxDirectoryCount)
        }
    }

    /// 作るディレクトリの数（ディレクトリの項目と、ファイルの親）。同じパスは 1 つと数える。
    /// 深いパスでも名前の長さの合計に比例する手間で済むよう、要素の木を作って数える（要素はバイト列で比べる）
    private static func directoryCount(of planned: [PlannedEntry]) -> Int {
        var children: [[[UInt8]: Int]] = [[:]]
        for item in planned {
            let directories = item.isDirectory ? item.components[...] : item.components.dropLast()
            var node = 0
            for component in directories {
                let key = Array(component.utf8)
                if let child = children[node][key] {
                    node = child
                } else {
                    children.append([:])
                    children[node][key] = children.count - 1
                    node = children.count - 1
                }
            }
        }
        return children.count - 1
    }

    /// 展開すると決めた項目を書く。既にあるパスと重なった項目は飛ばす
    private func write(
        _ planned: [PlannedEntry],
        from zip: AttachmentZipArchive,
        into root: String
    ) throws(AttachmentZipError) -> (written: [WrittenFile], conflicts: [IndexedSkip]) {
        do {
            try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        } catch {
            throw .cannotWrite(reason: error.localizedDescription)
        }
        var writer = AttachmentZipWriter(root: root, limit: limits.maxTotalBytes)
        var written: [WrittenFile] = []
        var conflicts: [IndexedSkip] = []
        for item in planned {
            if item.isDirectory {
                if try !writer.makeDirectory(item.components) {
                    conflicts.append((item.index, Self.skippedEntry(item.entry, reason: .conflict)))
                }
            } else if let path = try writer.writeFile(item.components, entry: item.entry, from: zip) {
                let entryPath = item.components.joined(separator: "/")
                written.append(WrittenFile(entryPath: entryPath, path: path, size: item.entry.uncompressedSize))
            } else {
                conflicts.append((item.index, Self.skippedEntry(item.entry, reason: .conflict)))
            }
        }
        return (written, conflicts)
    }

    /// 読ませる種類なら MIME タイプ。テキストと SVG は UTF-8 として読めなければ素材にする（バイナリの `.plist` など）
    private static func readableType(of path: String) -> String? {
        guard let type = AttachmentZipContentType.type(forPath: path) else {
            return nil
        }
        guard AttachmentZipContentType.requiresUTF8(type) else {
            return type
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe),
              String(bytes: data, encoding: .utf8) != nil else {
            return nil
        }
        return type
    }

    private static func skippedEntry(
        _ entry: AttachmentZipArchive.Entry,
        reason: AttachmentZipSkipReason
    ) -> AttachmentZipContents.SkippedEntry {
        .init(entryPath: AttachmentZipEntryRule.displayName(of: entry.nameBytes), reason: reason)
    }

    // MARK: - 展開した後の確かめ

    /// 展開先の下に、シンボリックリンク・ファイルとディレクトリ以外・展開先の外を指すものが無く、ファイルの数と大きさの合計が上限以内か。
    /// `.unsafeExtraction` の `path` は展開先からの相対パス
    static func verify(root: String, limits: Limits) throws(AttachmentZipError) {
        // `enumerator(atPath:)` の属性はリンクをたどらない（lstat）ので、リンクそのものを見分けられる
        guard let realRoot = realPath(root), let enumerator = FileManager.default.enumerator(atPath: root) else {
            throw .cannotWrite(reason: "展開先を読めませんでした")
        }
        var count = 0
        var directories = 0
        var total = 0
        while let relative = enumerator.nextObject() as? String {
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            guard type == .typeRegular || type == .typeDirectory,
                  let real = realPath("\(root)/\(relative)"), isInside(real, realRoot) else {
                throw .unsafeExtraction(path: relative)
            }
            if type == .typeRegular {
                count += 1
                total += (enumerator.fileAttributes?[.size] as? NSNumber)?.intValue ?? 0
            } else {
                directories += 1
            }
        }
        guard directories <= limits.maxDirectoryCount else {
            throw .tooManyDirectories(count: directories, limit: limits.maxDirectoryCount)
        }
        guard count <= limits.maxFileCount else {
            throw .tooManyFiles(count: count, limit: limits.maxFileCount)
        }
        guard total <= limits.maxTotalBytes else {
            throw .extractedTooLarge(limit: limits.maxTotalBytes)
        }
    }

    /// シンボリックリンクを解決した形。`URL.resolvingSymlinksInPath()` は `/private` を外すので `realpath(3)` を使う
    private static func realPath(_ path: String) -> String? {
        guard let pointer = realpath(path, nil) else {
            return nil
        }
        defer { free(pointer) }
        return trimmingTrailingSlashes(String(cString: pointer))
    }

    /// パスの比べ方と区切りは UTF-8 のバイトの単位で行う。`String` の `hasPrefix` は書記素クラスタの単位で、
    /// 名前が結合文字で始まると `"/\u{301}"` が 1 つの文字にまとまり、展開先の下にあるものを外と見誤る
    private static func isInside(_ path: String, _ root: String) -> Bool {
        let prefix = Array(root.utf8) + [UInt8(ascii: "/")]
        return path.utf8.starts(with: prefix)
    }

    private static func isSameOrInside(_ path: String, _ root: String) -> Bool {
        path.utf8.elementsEqual(root.utf8) || isInside(path, root)
    }

    private static func trimmingTrailingSlashes(_ path: String) -> String {
        var bytes = Array(path.utf8)
        while bytes.count > 1, bytes.last == UInt8(ascii: "/") {
            bytes.removeLast()
        }
        return String(bytes: bytes, encoding: .utf8) ?? path
    }
}
