import Foundation

/// `notifications.json`（進行を止めるものを知らせた記録）。司令塔だけが書く。
///
/// 知らせた出来事を `key` で持ち、同じ出来事を二度送らない。`key` は出来事ごとに決まる文字列で、質問の版・ジョブの試行の番号・
/// Mac の生きている印の時刻などを含む（同じ質問でも、見直して版が変われば別の出来事になる。形は `docs/renewal/protocol.md`）
public struct NotificationsFile: StateFile {
    public static let formatVersion = 1

    public struct Entry: Codable, Equatable, Sendable {
        /// 知らせた出来事
        public var key: String
        /// 知らせた時刻（送る前に書く）
        public var at: Timestamp

        public init(key: String, at: Timestamp) {
            self.key = key
            self.at = at
        }
    }

    public var sent: [Entry]

    public init(sent: [Entry] = []) {
        self.sent = sent
    }

    public var violations: [String] {
        var violations: [String] = []
        if let key = sent.first(where: { !Self.isKey($0.key) })?.key { violations.append("key の形が違う（\(key)）") }
        if Set(sent.map(\.key)).count != sent.count { violations.append("key が重複している") }
        return violations
    }

    /// 英数字と `._:-` の部品を `/` でつないだ 1〜300 文字（リポジトリの owner/name・ULID・時刻を含められる形）
    public static func isKey(_ key: String) -> Bool {
        (1...300).contains(key.utf8.count) && key.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: ":"), UInt8(ascii: "-"), UInt8(ascii: "/")].contains(byte)
        }
    }
}
