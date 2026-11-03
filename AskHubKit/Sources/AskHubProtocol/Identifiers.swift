import Foundation

// 状態リポジトリのパスの一部になる値と、時刻の形。
// パスに使う値は、読むときに形を確かめる（`..` や `/` を含む値で、ほかのファイルを指せないようにする）。

/// 時刻の順に並ぶ一意な id（ULID。Crockford の base32 で 26 文字）。epic・ジョブ・人の意図の `nonce` に使う
public struct ULID: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        // 先頭の文字は 0〜7（48 ビットの時刻の上限）
        guard rawValue.utf8.count == 26,
              let first = rawValue.utf8.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(first),
              rawValue.utf8.allSatisfy(Self.alphabet.contains) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    private static let alphabet = Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ".utf8)
}

/// GitHub のリポジトリの `owner/name`。GitHub が返す `full_name` のまま（大文字と小文字も）書く
public struct RepositoryFullName: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, Self.isOwner(parts[0]), Self.isName(parts[1]) else { return nil }
        self.rawValue = rawValue
    }

    public var owner: String { String(rawValue.prefix { $0 != "/" }) }
    public var name: String { String(rawValue.drop { $0 != "/" }.dropFirst()) }
    public var description: String { rawValue }

    /// 英数字とハイフンで 1〜39 文字。ハイフンで始まらない
    private static func isOwner(_ text: Substring) -> Bool {
        (1...39).contains(text.utf8.count) && text.first != "-" && text.utf8.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: "-") }
    }

    /// 英数字と `.`・`_`・`-` で 1〜100 文字。`.` と `..` ではない
    private static func isName(_ text: Substring) -> Bool {
        (1...100).contains(text.utf8.count) && text != "." && text != ".."
            && text.utf8.allSatisfy { isAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }
}

/// 公開鍵の id（SubjectPublicKeyInfo の DER の SHA-256 を base64url にした 43 文字）。端末の id にも使う
public struct KeyID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.utf8.count == 43,
              rawValue.utf8.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: "-") || $0 == UInt8(ascii: "_") }) else {
            return nil
        }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// プロトコルで使う時刻。UTC の ISO 8601 で、秒まで（`2026-11-03T10:00:00Z`）
public struct Timestamp: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    /// 秒に切り捨てた時刻
    public let date: Date

    public init(_ date: Date) {
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// 決まった形でなければ `nil`（小数の秒・時差の表記・存在しない日付を受け付けない）
    public init?(rawValue: String) {
        guard Self.hasShape(rawValue), let date = try? Date(rawValue, strategy: Self.style),
              date.formatted(Self.style) == rawValue else {
            return nil
        }
        self.date = date
    }

    public var rawValue: String { date.formatted(Self.style) }
    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.date < rhs.date }

    private static let style = Date.ISO8601FormatStyle()

    /// `dddd-dd-ddTdd:dd:ddZ` の形か
    private static func hasShape(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        guard bytes.count == 20 else { return false }
        let separators: [Int: UInt8] = [
            4: UInt8(ascii: "-"), 7: UInt8(ascii: "-"), 10: UInt8(ascii: "T"),
            13: UInt8(ascii: ":"), 16: UInt8(ascii: ":"), 19: UInt8(ascii: "Z")
        ]
        return bytes.indices.allSatisfy { index in
            if let separator = separators[index] { return bytes[index] == separator }
            return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index])
        }
    }
}

private func isAlphanumeric(_ byte: UInt8) -> Bool {
    (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
}
