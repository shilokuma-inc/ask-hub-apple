import Foundation

extension InboxIssue {
    /// 「実機確認」「任意判断」の一覧で、リポジトリごとに付ける色のパレットの添字（Discussion #563 の Q2）。
    ///
    /// `repository`（`owner/repo`）だけから決まるので、同じリポジトリの Issue は同じ色になる
    public func repositoryColorIndex(paletteCount: Int) -> Int? {
        Self.colorIndex(repository: repository, paletteCount: paletteCount)
    }

    /// リポジトリ名（`owner/repo`）から色のパレットの添字を決める。`paletteCount` が 0 以下なら `nil`。
    ///
    /// GitHub のリポジトリ名は大文字小文字を区別しないので、小文字にそろえてから FNV-1a で求める
    /// （取り直しても起動し直しても同じリポジトリは同じ色。`hashValue` / `Hasher` はプロセスごとに値が変わるので使わない）
    public static func colorIndex(repository: String, paletteCount: Int) -> Int? {
        guard paletteCount > 0 else {
            return nil
        }
        return Int(InboxSubject.fnv1a(repository.lowercased()) % UInt64(paletteCount))
    }
}
