import AskHubProtocol
import Foundation

/// 対象のアプリのアイコンの元を、clone から探して取り出す（`docs/renewal/architecture.md` の「対象のアプリのアイコン」）
extension GitRepositoryWorkspace {
    /// 取り出すファイルの数の上限
    static let maximumAppIconFiles = 200
    /// 取り出すファイルの 1 つの大きさの上限（バイト。git を流した結果は 4 MB を超えると末尾だけになる）
    static let maximumAppIconFileSize = 3_000_000
    /// 取り出すファイルの合計の大きさの上限（バイト）
    static let maximumAppIconTotalSize = 30_000_000

    /// clone を最新にしてから、base（nil なら既定のブランチ）の先頭のアイコンの元を探す。見つからなければ nil。
    /// clone を使った印は付けない（アイコンを確かめるためだけに、使っていない clone を残し続けないように）
    public func locateAppIcon(_ repo: RepositoryFullName, base: String?) async throws(WorkspaceError) -> AppIconLocator.Source? {
        let clone = cloneDirectory(of: repo)
        var listing = ""
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            try await update(clone, of: repo)
            let start = try await readingPoint(base: base, in: clone)
            listing = try await git(["ls-tree", "-r", "-d", "-z", start], in: clone)
        }
        return AppIconLocator.choose(fromTreeListing: listing)
    }

    /// アイコンの元のフォルダの中身を、`directory` の下に同じ名前のフォルダで取り出し、そのフォルダを返す。
    /// partial clone なので、無い中身はここで取りに行く。シンボリックリンクは取り出さない
    public func exportAppIcon(
        _ source: AppIconLocator.Source,
        of repo: RepositoryFullName,
        to directory: URL
    ) async throws(WorkspaceError) -> URL {
        let name = source.path.split(separator: "/").last.map(String.init) ?? ""
        guard AppIconLocator.isSafeRelativePath(name) else { throw .failed("アイコンの元の名前の形が違う（\(source.path)）") }
        let folder = directory.appendingPathComponent(name, isDirectory: true)
        let clone = cloneDirectory(of: repo)
        try await locks.withLock(repo.rawValue) { () throws(WorkspaceError) in
            // `-l` で大きさを読むときに、無い中身を取りに行く
            let listing = try await git(["ls-tree", "-r", "-l", "-z", source.tree], in: clone)
            guard let blobs = AppIconLocator.blobs(fromListing: listing) else {
                throw .failed("アイコンの元に、取り出せないパスがある（\(source.path)）")
            }
            guard blobs.count <= Self.maximumAppIconFiles,
                  blobs.allSatisfy({ $0.size <= Self.maximumAppIconFileSize }),
                  blobs.reduce(0, { $0 + $1.size }) <= Self.maximumAppIconTotalSize else {
                throw .failed("アイコンの元が大きすぎる（\(source.path)。\(blobs.count) ファイル）")
            }
            try remove(folder)
            for blob in blobs {
                let result = try await run(["cat-file", "blob", blob.sha], in: clone)
                guard result.succeeded else { throw Self.classify(result, command: "cat-file") }
                guard result.standardOutput.count == blob.size else { throw .failed("\(blob.path) を最後まで読めない") }
                let file = folder.appendingPathComponent(blob.path)
                try createDirectory(file.deletingLastPathComponent())
                do {
                    try result.standardOutput.write(to: file)
                } catch {
                    throw .failed("\(blob.path) を書けない（\(error.localizedDescription)）")
                }
            }
        }
        return folder
    }
}
