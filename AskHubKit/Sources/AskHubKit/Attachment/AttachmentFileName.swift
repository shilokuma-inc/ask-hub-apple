import Foundation

/// 添付のパスに使うファイル名の決まり（`docs/protocol.md` の「添付ファイル」の「パス」）
public enum AttachmentFileName {
    /// 安全にした後のファイル名の長さの上限（文字数）。超えた分は拡張子を残して前を詰める
    public static let maxLength = 100

    /// 何も残らなかったときの名前
    public static let fallback = "attachment"

    /// 元の名前から `/`・`\`・制御文字・先頭の `.` と前後の空白を除き、長さを上限に収める。空になったら `attachment` にする。
    ///
    /// 2 回かけても結果が変わらない（読む側は、パスのファイル名がこの結果と一致することを確かめるため）
    public static func sanitized(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        }
        // `. x.png` のように、先頭の `.` を除くと空白が先頭に出るので、変わらなくなるまで繰り返す
        var trimmed = String(String.UnicodeScalarView(scalars))
        while true {
            // `.` の直後に結合文字が続くと 1 つの Character になるので、Unicode スカラーの単位で落とす
            let next = String(trimmed.trimmingCharacters(in: .whitespaces).unicodeScalars.drop { $0 == "." })
            if next == trimmed {
                break
            }
            trimmed = next
        }
        // 詰めた結果の末尾が空白になることがある
        let shortened = shorten(trimmed).trimmingCharacters(in: .whitespaces)
        return shortened.isEmpty ? fallback : shortened
    }

    /// 拡張子（最後の `.` から後ろ。10 文字まで）を残して、全体を `maxLength` 文字に収める
    private static func shorten(_ name: String) -> String {
        guard name.count > maxLength else {
            return name
        }
        let maxExtensionLength = 10
        if let dot = name.lastIndex(of: "."), name.distance(from: dot, to: name.endIndex) <= maxExtensionLength + 1 {
            let suffix = name[dot...]
            return String(name[..<dot].prefix(maxLength - suffix.count)) + suffix
        }
        return String(name.prefix(maxLength))
    }
}
