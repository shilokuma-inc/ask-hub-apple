import Foundation

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
