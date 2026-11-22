import CryptoKit
import Foundation

/// GitHub の Secrets に入れる値を、リポジトリの公開鍵で暗号化する（libsodium の `crypto_box_seal` と同じ形。GitHub の文書の求める形）。
///
/// クライアントが値を受け取ったその場で暗号化し、暗号文だけを署名した人の意図に入れる（`docs/renewal/security.md` の「管理用のトークン」）。
/// 暗号文を解けるのは、公開鍵の持ち主の GitHub だけ。司令塔・状態リポジトリ・ログには平文を出さない。
///
/// 形: 使い捨ての X25519 の公開鍵（32 バイト）‖ Poly1305 のタグ（16 バイト）‖ XSalsa20 で暗号化した値。
/// nonce は BLAKE2b（24 バイト）（使い捨ての公開鍵 ‖ 相手の公開鍵）。鍵は X25519 の共有の値を HSalsa20 に通したもの
public enum SealedBox {
    /// 公開鍵の長さ（X25519）
    public static let publicKeyLength = 32
    /// 暗号文が値より長くなる分（使い捨ての公開鍵とタグ）
    public static let overhead = 48

    public enum Failure: Error, Equatable, Sendable {
        /// 公開鍵が 32 バイトの X25519 の鍵でない
        case invalidPublicKey
    }

    /// `message` を `publicKey`（GitHub の Secrets の公開鍵。base64 を解いた 32 バイト）に向けて暗号化する
    public static func seal(_ message: Data, to publicKey: Data) throws(Failure) -> Data {
        try seal(message, to: publicKey, ephemeral: Curve25519.KeyAgreement.PrivateKey())
    }

    /// 使い捨ての鍵を決めて暗号化する（テスト用）
    static func seal(_ message: Data, to publicKey: Data, ephemeral: Curve25519.KeyAgreement.PrivateKey) throws(Failure) -> Data {
        guard publicKey.count == publicKeyLength,
              let recipient = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey),
              let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: recipient) else {
            throw .invalidPublicKey
        }
        let ephemeralPublic = [UInt8](ephemeral.publicKey.rawRepresentation)
        let nonce = Blake2b.hash(ephemeralPublic + [UInt8](publicKey), outputLength: 24)
        let point = shared.withUnsafeBytes { [UInt8]($0) }
        return Data(ephemeralPublic + box([UInt8](message), nonce: nonce, sharedPoint: point))
    }

    /// `crypto_box_easy`: X25519 の共有の値から鍵を作り、タグ ‖ 暗号文を返す
    static func box(_ message: [UInt8], nonce: [UInt8], sharedPoint: [UInt8]) -> [UInt8] {
        secretbox(message, nonce: nonce, key: Salsa20.hsalsa20(key: sharedPoint, input: [UInt8](repeating: 0, count: 16)))
    }

    /// `crypto_secretbox_easy`（XSalsa20-Poly1305）: タグ ‖ 暗号文
    static func secretbox(_ message: [UInt8], nonce: [UInt8], key: [UInt8]) -> [UInt8] {
        let subkey = Salsa20.hsalsa20(key: key, input: Array(nonce[0..<16]))
        let stream = Salsa20.stream(key: subkey, nonce: Array(nonce[16..<24]), count: 32 + message.count)
        let cipher = zip(message, stream[32...]).map { $0 ^ $1 }
        return Poly1305.tag(cipher, key: Array(stream[0..<32])) + cipher
    }
}

/// Salsa20 と HSalsa20（XSalsa20 の鍵を作る）
enum Salsa20 {
    /// "expand 32-byte k"
    private static let sigma: [UInt32] = [0x6170_7865, 0x3320_646e, 0x7962_2d32, 0x6b20_6574]

    /// 鍵（32 バイト）と 16 バイトの入力から、32 バイトの鍵を作る
    static func hsalsa20(key: [UInt8], input: [UInt8]) -> [UInt8] {
        let keyWords = words(key)
        let inputWords = words(input)
        var state = [sigma[0]] + keyWords[0..<4] + [sigma[1]] + inputWords + [sigma[2]] + keyWords[4..<8] + [sigma[3]]
        doubleRounds(&state)
        return bytes([state[0], state[5], state[10], state[15], state[6], state[7], state[8], state[9]])
    }

    /// 鍵（32 バイト）と nonce（8 バイト）の鍵の流れを、`count` バイト（ブロックの番号は 0 から）
    static func stream(key: [UInt8], nonce: [UInt8], count: Int) -> [UInt8] {
        let keyWords = words(key)
        let nonceWords = words(nonce)
        var output: [UInt8] = []
        output.reserveCapacity(count + 64)
        var counter: UInt64 = 0
        while output.count < count {
            let initial = [sigma[0]] + keyWords[0..<4] + [sigma[1]] + nonceWords
                + [UInt32(truncatingIfNeeded: counter), UInt32(truncatingIfNeeded: counter >> 32)]
                + [sigma[2]] + keyWords[4..<8] + [sigma[3]]
            var state = initial
            doubleRounds(&state)
            output += bytes(zip(state, initial).map { $0 &+ $1 })
            counter += 1
        }
        return Array(output.prefix(count))
    }

    /// 20 ラウンド（列と行を 10 回）
    private static func doubleRounds(_ x: inout [UInt32]) {
        func quarter(_ i0: Int, _ i1: Int, _ i2: Int, _ i3: Int) {
            x[i1] ^= rotate(x[i0] &+ x[i3], 7)
            x[i2] ^= rotate(x[i1] &+ x[i0], 9)
            x[i3] ^= rotate(x[i2] &+ x[i1], 13)
            x[i0] ^= rotate(x[i3] &+ x[i2], 18)
        }
        for _ in 0..<10 {
            quarter(0, 4, 8, 12)
            quarter(5, 9, 13, 1)
            quarter(10, 14, 2, 6)
            quarter(15, 3, 7, 11)
            quarter(0, 1, 2, 3)
            quarter(5, 6, 7, 4)
            quarter(10, 11, 8, 9)
            quarter(15, 12, 13, 14)
        }
    }

    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}

/// Poly1305（使い捨ての鍵の MAC。26 ビットずつの 5 つの数で 2^130 - 5 を法に計算する）
enum Poly1305 {
    static func tag(_ message: [UInt8], key: [UInt8]) -> [UInt8] {
        let mask: UInt32 = 0x3ff_ffff
        let r0 = le32(key, 0) & 0x3ff_ffff
        let r1 = (le32(key, 3) >> 2) & 0x3ff_ff03
        let r2 = (le32(key, 6) >> 4) & 0x3ff_c0ff
        let r3 = (le32(key, 9) >> 6) & 0x3f0_3fff
        let r4 = (le32(key, 12) >> 8) & 0x00f_ffff
        let (s1, s2, s3, s4) = (r1 * 5, r2 * 5, r3 * 5, r4 * 5)
        var acc: [UInt32] = [0, 0, 0, 0, 0]
        var offset = 0
        while offset < message.count {
            var block = Array(message[offset..<min(offset + 16, message.count)])
            let full = block.count == 16
            if !full {
                block.append(1)
                block += [UInt8](repeating: 0, count: 16 - block.count)
            }
            acc[0] &+= le32(block, 0) & mask
            acc[1] &+= (le32(block, 3) >> 2) & mask
            acc[2] &+= (le32(block, 6) >> 4) & mask
            acc[3] &+= (le32(block, 9) >> 6) & mask
            acc[4] &+= (le32(block, 12) >> 8) | (full ? 1 << 24 : 0)
            let (h0, h1, h2, h3, h4) = (UInt64(acc[0]), UInt64(acc[1]), UInt64(acc[2]), UInt64(acc[3]), UInt64(acc[4]))
            let d0 = h0 * UInt64(r0) + h1 * UInt64(s4) + h2 * UInt64(s3) + h3 * UInt64(s2) + h4 * UInt64(s1)
            var d1 = h0 * UInt64(r1) + h1 * UInt64(r0) + h2 * UInt64(s4) + h3 * UInt64(s3) + h4 * UInt64(s2)
            var d2 = h0 * UInt64(r2) + h1 * UInt64(r1) + h2 * UInt64(r0) + h3 * UInt64(s4) + h4 * UInt64(s3)
            var d3 = h0 * UInt64(r3) + h1 * UInt64(r2) + h2 * UInt64(r1) + h3 * UInt64(r0) + h4 * UInt64(s4)
            var d4 = h0 * UInt64(r4) + h1 * UInt64(r3) + h2 * UInt64(r2) + h3 * UInt64(r1) + h4 * UInt64(r0)
            var carry = d0 >> 26
            acc[0] = UInt32(d0 & UInt64(mask))
            d1 += carry
            carry = d1 >> 26
            acc[1] = UInt32(d1 & UInt64(mask))
            d2 += carry
            carry = d2 >> 26
            acc[2] = UInt32(d2 & UInt64(mask))
            d3 += carry
            carry = d3 >> 26
            acc[3] = UInt32(d3 & UInt64(mask))
            d4 += carry
            carry = d4 >> 26
            acc[4] = UInt32(d4 & UInt64(mask))
            acc[0] &+= UInt32(carry) &* 5
            let top = acc[0] >> 26
            acc[0] &= mask
            acc[1] &+= top
            offset += 16
        }
        return finish(acc, key: key)
    }

    /// 最後の繰り上げ・法による引き算・鍵の後半（pad）の足し算
    private static func finish(_ value: [UInt32], key: [UInt8]) -> [UInt8] {
        let mask: UInt32 = 0x3ff_ffff
        var acc = value
        var carry = acc[1] >> 26
        acc[1] &= mask
        for index in 2...4 {
            acc[index] &+= carry
            carry = acc[index] >> 26
            acc[index] &= mask
        }
        acc[0] &+= carry &* 5
        carry = acc[0] >> 26
        acc[0] &= mask
        acc[1] &+= carry
        // reduced = acc + (-p)
        var reduced = [UInt32](repeating: 0, count: 5)
        reduced[0] = acc[0] &+ 5
        carry = reduced[0] >> 26
        reduced[0] &= mask
        for index in 1...3 {
            reduced[index] = acc[index] &+ carry
            carry = reduced[index] >> 26
            reduced[index] &= mask
        }
        reduced[4] = acc[4] &+ carry &- (1 << 26)
        // acc が p 以上なら reduced を使う
        let select = (reduced[4] >> 31) &- 1
        acc = (0..<5).map { (acc[$0] & ~select) | (reduced[$0] & select) }
        let words: [UInt32] = [
            acc[0] | (acc[1] << 26),
            (acc[1] >> 6) | (acc[2] << 20),
            (acc[2] >> 12) | (acc[3] << 14),
            (acc[3] >> 18) | (acc[4] << 8)
        ]
        var sum: UInt64 = 0
        var output: [UInt32] = []
        for index in 0..<4 {
            sum = UInt64(words[index]) + UInt64(le32(key, 16 + index * 4)) + (sum >> 32)
            output.append(UInt32(truncatingIfNeeded: sum))
        }
        return bytes(output)
    }
}

/// BLAKE2b（鍵なし。`outputLength` バイトの要約）
enum Blake2b {
    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179
    ]

    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0]
    ]

    static func hash(_ input: [UInt8], outputLength: Int) -> [UInt8] {
        precondition((1...64).contains(outputLength), "BLAKE2b の長さは 1〜64 バイト")
        var state = iv
        state[0] ^= 0x0101_0000 ^ UInt64(outputLength)
        var offset = 0
        repeat {
            let end = min(offset + 128, input.count)
            let last = end == input.count
            var block = Array(input[offset..<end])
            block += [UInt8](repeating: 0, count: 128 - block.count)
            compress(&state, block: block, counter: UInt64(end), last: last)
            offset = end
        } while offset < input.count
        var output: [UInt8] = []
        for word in state {
            for byte in 0..<8 { output.append(UInt8(truncatingIfNeeded: word >> (UInt64(byte) * 8))) }
        }
        return Array(output.prefix(outputLength))
    }

    private static func compress(_ state: inout [UInt64], block: [UInt8], counter: UInt64, last: Bool) {
        var input = [UInt64](repeating: 0, count: 16)
        for index in 0..<128 {
            let shift = UInt64(index % 8) * 8
            input[index / 8] |= UInt64(block[index]) << shift
        }
        var work = state + iv
        work[12] ^= counter
        if last { work[14] = ~work[14] }
        func mix(_ lanes: [Int], _ x: UInt64, _ y: UInt64) {
            let (i0, i1, i2, i3) = (lanes[0], lanes[1], lanes[2], lanes[3])
            work[i0] = work[i0] &+ work[i1] &+ x
            work[i3] = rotate(work[i3] ^ work[i0], 32)
            work[i2] = work[i2] &+ work[i3]
            work[i1] = rotate(work[i1] ^ work[i2], 24)
            work[i0] = work[i0] &+ work[i1] &+ y
            work[i3] = rotate(work[i3] ^ work[i0], 16)
            work[i2] = work[i2] &+ work[i3]
            work[i1] = rotate(work[i1] ^ work[i2], 63)
        }
        for round in 0..<12 {
            let order = sigma[round % 10]
            mix([0, 4, 8, 12], input[order[0]], input[order[1]])
            mix([1, 5, 9, 13], input[order[2]], input[order[3]])
            mix([2, 6, 10, 14], input[order[4]], input[order[5]])
            mix([3, 7, 11, 15], input[order[6]], input[order[7]])
            mix([0, 5, 10, 15], input[order[8]], input[order[9]])
            mix([1, 6, 11, 12], input[order[10]], input[order[11]])
            mix([2, 7, 8, 13], input[order[12]], input[order[13]])
            mix([3, 4, 9, 14], input[order[14]], input[order[15]])
        }
        for index in 0..<8 { state[index] ^= work[index] ^ work[index + 8] }
    }

    private static func rotate(_ value: UInt64, _ count: UInt64) -> UInt64 {
        (value >> count) | (value << (64 - count))
    }
}

/// 小さい順（リトルエンディアン）の 32 ビットの数
private func le32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    (0..<4).reduce(UInt32(0)) { word, index in word | UInt32(bytes[offset + index]) << (UInt32(index) * 8) }
}

private func words(_ bytes: [UInt8]) -> [UInt32] {
    stride(from: 0, to: bytes.count, by: 4).map { le32(bytes, $0) }
}

private func bytes(_ words: [UInt32]) -> [UInt8] {
    words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (UInt32($0) * 8)) } }
}
