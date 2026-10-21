import Foundation

/// 添付のパスに使うファイル名の決まり（`docs/protocol.md` の「添付ファイル」の「パス」）
public enum AttachmentFileName {
    /// 安全にした後のファイル名の長さの上限（文字数）。超えた分は拡張子を残して前を詰める
    public static let maxLength = 100

    /// 何も残らなかったときの名前
    public static let fallback = "attachment"

    /// 元の名前から `/`・`\`・制御文字・先頭の `.` を除き、長さを上限に収める。空になったら `attachment` にする
    public static func sanitized(_ name: String) -> String {
        let scalars = name.unicodeScalars.filter { scalar in
            scalar != "/" && scalar != "\\" && !CharacterSet.controlCharacters.contains(scalar)
        }
        let trimmed = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespaces)
            .drop { $0 == "." }
        let shortened = shorten(String(trimmed))
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

/// 添付の種類（`claude` が読めるもの。Discussion #669 の Q2）
public enum AttachmentKind: Sendable, Equatable {
    case text
    case image
    case pdf

    /// MIME タイプから決める。`image/` で始まるものは画像、`application/pdf` は PDF、それ以外はテキスト
    public init(mimeType: String) {
        let type = mimeType.lowercased()
        if type.hasPrefix("image/") {
            self = .image
        } else if type == "application/pdf" {
            self = .pdf
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
        }
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
        if value < kilo * kilo {
            return "\(Int((value / kilo).rounded())) KB"
        }
        let megabytes = value / (kilo * kilo)
        return String(format: "%.1f MB", locale: Locale(identifier: "en_US_POSIX"), megabytes)
    }
}
