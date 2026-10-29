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

/// 添付の種類（`claude` が読めるもの。Discussion #669 の Q2・zip は Discussion #761 の Q1）
public enum AttachmentKind: Sendable, Equatable {
    case text
    case image
    case pdf
    /// 受け取る側（macOS の担当 PC）で展開して使う zip
    case zip

    /// MIME タイプから決める。`image/` で始まるものは画像、`application/pdf` は PDF、`application/zip`（と `application/x-zip-compressed`）は zip、
    /// それ以外はテキスト
    public init(mimeType: String) {
        let type = Self.essence(of: mimeType)
        if type.hasPrefix("image/") {
            self = .image
        } else if type == "application/pdf" {
            self = .pdf
        } else if Self.zipTypes.contains(type) {
            self = .zip
        } else {
            self = .text
        }
    }

    /// 添付欄に出す名前
    public var displayName: String {
        switch self {
        case .text:
            "テキスト"

        case .image:
            "画像"

        case .pdf:
            "PDF"

        case .zip:
            "zip"
        }
    }

    /// SVG（`image/svg+xml`）か。種類は画像だが、中身は XML のテキストなので UTF-8 で読めることを確かめる
    public static func isSVG(mimeType: String) -> Bool {
        essence(of: mimeType) == "image/svg+xml"
    }

    /// zip として読む MIME タイプ。`application/x-zip-compressed` は Windows のブラウザなどが付ける
    private static let zipTypes: Set<String> = ["application/zip", "application/x-zip-compressed"]

    /// `application/pdf; charset=…` のような引数を落とし、小文字にした MIME タイプ
    private static func essence(of mimeType: String) -> String {
        let essence = mimeType.split(separator: ";", maxSplits: 1).first ?? ""
        return essence.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// 添付の大きさの表示（例: `512 B`・`120 KB`・`3.4 MB`）。1 KB = 1,024 バイト
public enum AttachmentSize {
    public static func displayText(bytes: Int) -> String {
        let kilo = 1_024.0
        let value = Double(max(bytes, 0))
        if value < kilo {
            return "\(Int(value)) B"
        }
        // 1 MB の手前で「1024 KB」と出さないよう、KB に丸めた値が 1024 に届いたら MB で出す
        let kilobytes = Int((value / kilo).rounded())
        if kilobytes < 1_024 {
            return "\(kilobytes) KB"
        }
        let megabytes = value / (kilo * kilo)
        return String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), megabytes)
    }
}
