import Foundation

/// アプリが一覧を取得する organization の login。
///
/// 検索クエリ（`org:`）にそのまま埋め込むので、空白や `:` を含むもの（ほかの修飾子になりうるもの）は扱わない
public enum TargetOrganizations {
    /// 既定の organization（Discussion #1 の Q6）
    public static let defaultLogins = ["shilokuma-inc"]

    /// GitHub の login として使える形か。英数字とハイフンで 39 文字まで、先頭はハイフン以外（検索で除外の `-` にならないため）
    public static func isValid(_ login: String) -> Bool {
        let scalars = Array(login.unicodeScalars)
        guard (1...39).contains(scalars.count), scalars.first != "-" else {
            return false
        }
        return scalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") }
    }

    /// 前後の空白を除き、使えないものと重なり（大文字・小文字を区別しない）を除く。順番は保つ
    public static func normalized(_ logins: [String]) -> [String] {
        var result: [String] = []
        for login in logins.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
        where isValid(login) && !result.contains(where: { $0.caseInsensitiveCompare(login) == .orderedSame }) {
            result.append(login)
        }
        return result
    }
}
