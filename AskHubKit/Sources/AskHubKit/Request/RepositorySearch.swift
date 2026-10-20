import Foundation

/// 名前で依頼先のリポジトリを探す（Siri・ショートカットで「ask hub apple」のように声で言った名前と照らし合わせる）
public enum RepositorySearch {
    /// `repositories`（`owner/repo`）のうち、`query` を含むもの（repo 名の一部でも `owner/repo` でも当たる）。元の順を保つ。
    /// 声で言いやすいよう、大文字小文字・`-`・`_`・空白の違いは無視する。`query` が空（無視する文字だけを含む）なら何も返さない
    public static func filter(_ repositories: [String], matching query: String) -> [String] {
        let key = normalized(query)
        guard !key.isEmpty else {
            return []
        }
        return repositories.filter { normalized($0).contains(key) }
    }

    /// 照らし合わせに使う形。小文字にして、`-`・`_`・空白を除く（`/` と `.` は残す）
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { !ignored.contains($0) })
    }

    private static let ignored = CharacterSet(charactersIn: "-_").union(.whitespacesAndNewlines)
}
