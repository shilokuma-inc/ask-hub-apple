import CryptoKit
import Foundation

extension ULID {
    private static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 時刻（UNIX 時刻のミリ秒、48 ビット）と 80 ビットの値から作る
    public init(milliseconds: UInt64, randomness: [UInt8]) {
        precondition(randomness.count == 10, "ULID のランダムな部分は 10 バイト")
        precondition(milliseconds < 1 << 48, "ULID の時刻は 48 ビットまで")
        var characters: [Character] = []
        // 時刻の 48 ビットを、5 ビットずつ 10 文字にする（先頭の 2 ビットは 0）
        for index in (0..<10).reversed() {
            characters.append(Self.alphabet[Int((milliseconds >> (UInt64(index) * 5)) & 31)])
        }
        // 80 ビットを、5 ビットずつ 16 文字にする
        var bits: UInt64 = 0
        var count = 0
        for byte in randomness {
            bits = (bits << 8) | UInt64(byte)
            count += 8
            while count >= 5 {
                count -= 5
                characters.append(Self.alphabet[Int((bits >> UInt64(count)) & 31)])
            }
        }
        guard let ulid = ULID(rawValue: String(characters)) else { preconditionFailure("ULID の形にならない") }
        self = ulid
    }

    /// その時刻の、新しい ULID（人の意図の `nonce`・epic・ジョブの id）
    public static func generate(at date: Date = Date()) -> ULID {
        var generator = SystemRandomNumberGenerator()
        let randomness = (0..<10).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return ULID(milliseconds: milliseconds(of: date), randomness: randomness)
    }

    /// 決まった材料から作る ULID。同じ材料なら同じ id になるので、途中で止まってやり直しても、同じものを 2 つ作らない。
    /// 時刻の部分は `base` と同じにして、並びの順を保つ
    public static func derived(from base: ULID, seed: String) -> ULID {
        let digest = Array(SHA256.hash(data: Data((base.rawValue + "/" + seed).utf8)))
        return ULID(milliseconds: base.milliseconds, randomness: Array(digest.prefix(10)))
    }

    /// 時刻の部分（UNIX 時刻のミリ秒）
    public var milliseconds: UInt64 {
        rawValue.prefix(10).reduce(UInt64(0)) { value, character in
            (value << 5) | UInt64(Self.alphabet.firstIndex(of: character) ?? 0)
        }
    }

    private static func milliseconds(of date: Date) -> UInt64 {
        UInt64(max(0, (date.timeIntervalSince1970 * 1000).rounded(.down)))
    }
}
