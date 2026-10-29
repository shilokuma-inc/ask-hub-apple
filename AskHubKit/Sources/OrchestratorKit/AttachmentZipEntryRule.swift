import AskHubKit
import Foundation

/// 中央ディレクトリの項目を展開するか・どこに展開するかの規則（`docs/protocol.md` の「zip の展開」の「展開しない項目」）。
/// 表の上から順に確かめ、最初に当てはまった理由を返す
enum AttachmentZipEntryRule {
    enum Plan: Equatable {
        /// 展開先の下の要素（`.` と空の要素を詰めたもの）
        case directory([String])
        case file([String])
        case skip(AttachmentZipSkipReason)
    }

    private static let unixDirectory: UInt32 = 0o040000
    private static let unixRegularFile: UInt32 = 0o100000
    private static let unixSymbolicLink: UInt32 = 0o120000
    /// MS-DOS の属性のディレクトリのビット
    private static let dosDirectory: UInt32 = 0x10

    static func plan(for entry: AttachmentZipArchive.Entry) -> Plan {
        // 汎用フラグの bit 11 は見ない（macOS の zip は UTF-8 の名前でも立てない）
        guard let name = String(bytes: entry.nameBytes, encoding: .utf8) else {
            return .skip(.unreadableName)
        }
        if let reason = unsafeNameReason(name) {
            return .skip(reason)
        }
        let components = name.split(separator: "/").map(String.init).filter { $0 != "." }
        let fileType = entry.unixFileType
        if fileType == unixSymbolicLink {
            return .skip(.symbolicLink)
        }
        if let fileType, ![0, unixRegularFile, unixDirectory].contains(fileType) {
            return .skip(.specialFile)
        }
        let isDosDirectory = entry.hostSystem == 0 && entry.externalAttributes & dosDirectory != 0
        let isDirectory = name.hasSuffix("/") || fileType == unixDirectory || isDosDirectory
        if !isDirectory, let reason = dataReason(of: entry) {
            return .skip(reason)
        }
        if isMacOSMetadata(components) {
            return .skip(.macOSMetadata)
        }
        return isDirectory ? .directory(components) : .file(components)
    }

    /// 危険な名前（制御文字・絶対パス・`\`・ドライブ名・`..`・空）の理由。安全なら `nil`
    private static func unsafeNameReason(_ name: String) -> AttachmentZipSkipReason? {
        if name.unicodeScalars.contains(where: isControl) {
            return .controlCharacter
        }
        if name.hasPrefix("/") {
            return .absolutePath
        }
        if name.contains("\\") || hasDriveLetter(name) {
            return .backslashOrDrive
        }
        let elements = name.split(separator: "/")
        if elements.contains("..") {
            return .parentDirectory
        }
        return elements.allSatisfy { $0 == "." } ? .emptyName : nil
    }

    /// ファイルの中身を解けない理由（暗号化・未対応の圧縮方式）
    private static func dataReason(of entry: AttachmentZipArchive.Entry) -> AttachmentZipSkipReason? {
        if entry.isEncrypted {
            return .encrypted
        }
        if entry.method != 0, entry.method != 8 {
            return .unsupportedCompression(method: entry.method)
        }
        return nil
    }

    /// `__MACOSX/`・`.DS_Store`・`._*`（AppleDouble）
    private static func isMacOSMetadata(_ components: [String]) -> Bool {
        guard let last = components.last else {
            return false
        }
        return components.contains("__MACOSX") || last == ".DS_Store" || last.hasPrefix("._")
    }

    /// 一覧に出す名前。UTF-8 として読めないバイトと制御文字は U+FFFD にする
    static func displayName(of bytes: [UInt8]) -> String {
        // 読めないバイトを U+FFFD にしたいので、置き換えて読む
        // swiftlint:disable:next optional_data_string_conversion
        let scalars = String(decoding: bytes, as: UTF8.self).unicodeScalars.map { isControl($0) ? "\u{FFFD}" : $0 }
        return String(String.UnicodeScalarView(scalars))
    }

    /// U+0000〜U+001F・U+007F〜U+009F
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value)
    }

    /// 先頭が英字 1 文字と `:`（`C:`）
    private static func hasDriveLetter(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars.prefix(2))
        return scalars.count == 2 && scalars[0].isASCII && scalars[0].properties.isAlphabetic && scalars[1] == ":"
    }
}

/// 展開したファイルの種類を拡張子で決める（`docs/protocol.md` の「zip の展開」の「読ませるもの・素材」）
enum AttachmentZipContentType {
    /// テキストの拡張子（仮決め）と MIME タイプ。MIME タイプは `AttachmentKind` でテキストになるもの
    private static let textTypes: [String: String] = [
        "md": "text/markdown",
        "markdown": "text/markdown",
        "txt": "text/plain",
        "json": "application/json",
        "csv": "text/csv",
        "tsv": "text/tab-separated-values",
        "yaml": "application/yaml",
        "yml": "application/yaml",
        "xml": "application/xml",
        "html": "text/html",
        "htm": "text/html",
        "css": "text/css",
        "js": "text/javascript",
        "ts": "text/x-typescript",
        "swift": "text/x-swift",
        "kt": "text/x-kotlin",
        "strings": "text/plain",
        "plist": "application/x-plist"
    ]

    private static let otherTypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "svg": "image/svg+xml",
        "pdf": "application/pdf"
    ]

    /// 読ませる種類なら MIME タイプ。それ以外（素材）は `nil`
    static func type(forFileName name: String) -> String? {
        let pathExtension = URL(fileURLWithPath: name).pathExtension.lowercased()
        return textTypes[pathExtension] ?? otherTypes[pathExtension]
    }

    /// 中身が UTF-8 として読めることを確かめる種類（テキストと SVG）
    static func requiresUTF8(_ type: String) -> Bool {
        AttachmentKind(mimeType: type) == .text || AttachmentKind.isSVG(mimeType: type)
    }
}
