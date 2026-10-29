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

    /// 名前の区切りは UTF-8 のバイト（= Unicode スカラー）の単位で見る。`String` の `split` や `hasPrefix` は書記素クラスタの単位なので、
    /// `/` の直後に結合文字（U+0301 など）があると `"/\u{301}"` が 1 つの文字にまとまり、`..` や先頭の `/` を見落とす
    private static let slash = UInt8(ascii: "/")
    private static let backslash = UInt8(ascii: "\\")
    private static let dot = UInt8(ascii: ".")
    private static let colon = UInt8(ascii: ":")

    static func plan(for entry: AttachmentZipArchive.Entry) -> Plan {
        let bytes = entry.nameBytes
        // 汎用フラグの bit 11 は見ない（macOS の zip は UTF-8 の名前でも立てない）
        guard let name = String(bytes: bytes, encoding: .utf8) else {
            return .skip(.unreadableName)
        }
        if let reason = unsafeNameReason(name, bytes: bytes) {
            return .skip(reason)
        }
        let components = pathComponents(of: bytes)
        let fileType = entry.unixFileType
        if fileType == unixSymbolicLink {
            return .skip(.symbolicLink)
        }
        if let fileType, ![0, unixRegularFile, unixDirectory].contains(fileType) {
            return .skip(.specialFile)
        }
        let isDosDirectory = entry.hostSystem == 0 && entry.externalAttributes & dosDirectory != 0
        let isDirectory = bytes.last == slash || fileType == unixDirectory || isDosDirectory
        if !isDirectory, let reason = dataReason(of: entry) {
            return .skip(reason)
        }
        if isMacOSMetadata(components) {
            return .skip(.macOSMetadata)
        }
        return isDirectory ? .directory(components) : .file(components)
    }

    /// 名前のバイト列を `/`（0x2F）で区切った要素。空の要素と `.` は詰める。
    /// UTF-8 の多バイト文字の中に 0x2F は現れないので、区切った要素も UTF-8 として読める
    static func pathComponents(of bytes: [UInt8]) -> [String] {
        bytes.split(separator: slash)
            .filter { !$0.elementsEqual([dot]) }
            .compactMap { String(bytes: $0, encoding: .utf8) }
    }

    /// 危険な名前（制御文字・絶対パス・`\`・ドライブ名・`..`・空）の理由。安全なら `nil`
    private static func unsafeNameReason(_ name: String, bytes: [UInt8]) -> AttachmentZipSkipReason? {
        if name.unicodeScalars.contains(where: isControl) {
            return .controlCharacter
        }
        if bytes.first == slash {
            return .absolutePath
        }
        if bytes.contains(backslash) || hasDriveLetter(bytes) {
            return .backslashOrDrive
        }
        let elements = bytes.split(separator: slash)
        if elements.contains(where: { $0.elementsEqual([dot, dot]) }) {
            return .parentDirectory
        }
        return elements.allSatisfy { $0.elementsEqual([dot]) } ? .emptyName : nil
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
        // 比べるのもバイト列で（`"._\u{301}"` も `._` で始まるものとして扱う）
        return components.contains { $0.utf8.elementsEqual("__MACOSX".utf8) }
            || last.utf8.elementsEqual(".DS_Store".utf8)
            || last.utf8.starts(with: "._".utf8)
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
    private static func hasDriveLetter(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2 else {
            return false
        }
        let first = bytes[0]
        let isLetter = (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(first) || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(first)
        return isLetter && bytes[1] == colon
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
    /// `path` の最後の要素の拡張子で決める。要素と拡張子は UTF-8 のバイトの `/`・`.` で区切る（結合文字で 1 つの文字にまとまっても区切る）。
    /// 先頭の `.` だけのもの（`.png`）は拡張子とみなさない
    static func type(forPath path: String) -> String? {
        let bytes = Array(path.utf8)
        let name = bytes.split(separator: UInt8(ascii: "/")).last ?? []
        guard let dot = name.lastIndex(of: UInt8(ascii: ".")), dot != name.startIndex,
              let pathExtension = String(bytes: name[(dot + 1)...], encoding: .utf8)?.lowercased() else {
            return nil
        }
        return textTypes[pathExtension] ?? otherTypes[pathExtension]
    }

    /// 中身が UTF-8 として読めることを確かめる種類（テキストと SVG）
    static func requiresUTF8(_ type: String) -> Bool {
        AttachmentKind(mimeType: type) == .text || AttachmentKind.isSVG(mimeType: type)
    }
}
