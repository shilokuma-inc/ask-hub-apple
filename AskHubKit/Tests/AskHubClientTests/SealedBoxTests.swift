@testable import AskHubClient
import CryptoKit
import Foundation
import Testing

/// GitHub の Secrets に入れる値の暗号化（libsodium の sealed box と同じ形）。部品ごとに公開された試験値で確かめる
struct SealedBoxTests {
    static func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { offset in
            let start = text.index(text.startIndex, offsetBy: offset)
            return UInt8(text[start..<text.index(start, offsetBy: 2)], radix: 16)!
        }
    }

    static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    // RFC 7748 の 6.1 の X25519 の鍵（NaCl の試験と同じ）
    static let aliceSecret = hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a")
    static let alicePublic = hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a")
    static let bobSecret = hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb")
    static let bobPublic = hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f")
    static let shared = hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742")
    static let nonce = hex("69696ee955b62b73cd62bda875fc73d68219e0036b7a0b37")

    @Test func x25519MatchesRFC7748() throws {
        let alice = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.aliceSecret)
        #expect([UInt8](alice.publicKey.rawRepresentation) == Self.alicePublic)
        let secret = try alice.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: Self.bobPublic))
        let point = secret.withUnsafeBytes { [UInt8]($0) }
        #expect(point == Self.shared)
    }

    /// NaCl の core1（HSalsa20）と stream3（XSalsa20 の最初の 32 バイト）
    @Test func hsalsa20AndStreamMatchNaCl() {
        let firstKey = Salsa20.hsalsa20(key: Self.shared, input: [UInt8](repeating: 0, count: 16))
        #expect(Self.hex(firstKey) == "1b27556473e985d462cd51197a9a46c76009549eac6474f206c4ee0844f68389")
        let subkey = Salsa20.hsalsa20(key: firstKey, input: Array(Self.nonce[0..<16]))
        let stream = Salsa20.stream(key: subkey, nonce: Array(Self.nonce[16..<24]), count: 32)
        #expect(Self.hex(stream) == "eea6a7251c1e72916d11c2cb214d3c252539121d8e234e652d651fa4c8cff880")
    }

    /// RFC 8439 の 2.5.2
    @Test func poly1305MatchesRFC8439() {
        let key = Self.hex("85d6be7857556d337f4452fe42d506a80103808afb0db2fd4abff6af4149f51b")
        let tag = Poly1305.tag(Array("Cryptographic Forum Research Group".utf8), key: key)
        #expect(Self.hex(tag) == "a8061dc1305136c6c22b8baf0c0127a9")
    }

    /// RFC 7693 の付録 A（64 バイト）と、Python の hashlib.blake2b(digest_size=24) で求めた値
    @Test func blake2bMatchesReference() {
        #expect(Self.hex(Blake2b.hash(Array("abc".utf8), outputLength: 64))
            == "ba80a53f981c4d0d6a2797b69f12f6e94c212f14685ac4b74b12bb6fdbffa2d1"
            + "7d87c5392aab792dc252d5de4533cc9518d38aa8dbf1925ab92386edd4009923")
        #expect(Self.hex(Blake2b.hash([], outputLength: 24)) == "ab3b5331a7135ed50d0f182d026e60abdb3646fd51bcf8a3")
        #expect(Self.hex(Blake2b.hash((0..<200).map(UInt8.init), outputLength: 24)) == "e9183c766451ac26ddd03b280b4b6000802b4b7230c78bb3")
        #expect(Self.hex(Blake2b.hash((0..<128).map(UInt8.init), outputLength: 24)) == "2f5f6c3d92c87ec6916cd0034fea92dfd83b28dc91485d41")
    }

    /// NaCl の box の試験（alice の秘密鍵・bob の公開鍵・nonce・131 バイトの値）
    @Test func boxMatchesNaCl() {
        let message = Self.hex(
            "be075fc53c81f2d5cf141316ebeb0c7b5228c52a4c62cbd44b66849b64244ffce5ecbaaf33bd751a1ac728d45e6c61296cdc3c01233561f41d"
                + "b66cce314adb310e3be8250c46f06dceea3a7fa1348057e2f6556ad6b1318a024a838f21af1fde048977eb48f59ffd4924ca1c60902e52f0"
                + "a089bc76897040e082f937763848645e0705"
        )
        let boxed = SealedBox.box(message, nonce: Self.nonce, sharedPoint: Self.shared)
        #expect(Self.hex(boxed)
            == "f3ffc7703f9400e52a7dfb4b3d3305d98e993b9f48681273c29650ba32fc76ce48332ea7164d96a4476fb8c531a1186ac0dfc17c98dce87b4da7"
                + "f011ec48c97271d2c20f9b928fe2270d6fb863d51738b48eeee314a7cc8ab932164548e526ae90224368517acfeabd6bb3732bc0e9da99832b"
                + "61ca01b6de56244a9e88d5f9b37973f622a43d14a6599b1f654cb45a74e355a5")
    }

    /// sealed box 全体: 使い捨ての公開鍵 ‖ box。nonce は libsodium の文書のとおり BLAKE2b（使い捨ての公開鍵 ‖ 相手の公開鍵）で、
    /// その値は Python の hashlib.blake2b(digest_size=24) で独立に求めたもの（並びを逆にすると b2a704a1… になり、一致しない）。
    /// box の部分は NaCl の試験値で確かめた `boxMatchesNaCl` と同じ計算
    @Test func sealedBoxMatchesLibsodiumComposition() throws {
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.aliceSecret)
        let message = Self.hex("be075fc53c81f2d5cf141316ebeb0c7b5228c52a4c62cbd44b66849b64244ffc")
        let sealed = try SealedBox.seal(Data(message), to: Data(Self.bobPublic), ephemeral: ephemeral)
        let nonce = Self.hex("bde68c3007dd6c6038618666c8830b023d3c0a8e988a8d38")
        #expect([UInt8](sealed) == Self.alicePublic + SealedBox.box(message, nonce: nonce, sharedPoint: Self.shared))
    }

    /// sealed box は、使い捨ての公開鍵 ‖ box。受け取る側（秘密鍵を持つ GitHub）が同じ手順で開ける
    @Test func sealedBoxOpensWithRecipientSecret() throws {
        let recipient = Curve25519.KeyAgreement.PrivateKey()
        let ephemeral = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: Self.aliceSecret)
        let message = Data("ghp_example-secret-値".utf8)
        let sealed = try SealedBox.seal(message, to: recipient.publicKey.rawRepresentation, ephemeral: ephemeral)
        #expect(sealed.count == message.count + SealedBox.overhead)
        #expect([UInt8](sealed.prefix(32)) == Self.alicePublic)
        // 開ける側: 使い捨ての公開鍵と自分の秘密鍵で共有の値を作り、同じ nonce で鍵の流れを作ってタグを確かめる
        let ephemeralPublic = [UInt8](sealed.prefix(32))
        let nonce = Blake2b.hash(ephemeralPublic + [UInt8](recipient.publicKey.rawRepresentation), outputLength: 24)
        let secret = try recipient.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: ephemeralPublic))
        let point = secret.withUnsafeBytes { [UInt8]($0) }
        let key = Salsa20.hsalsa20(key: point, input: [UInt8](repeating: 0, count: 16))
        let subkey = Salsa20.hsalsa20(key: key, input: Array(nonce[0..<16]))
        let cipher = [UInt8](sealed.dropFirst(48))
        let stream = Salsa20.stream(key: subkey, nonce: Array(nonce[16..<24]), count: 32 + cipher.count)
        #expect(Poly1305.tag(cipher, key: Array(stream[0..<32])) == [UInt8](sealed.dropFirst(32).prefix(16)))
        #expect(Data(zip(cipher, stream[32...]).map { $0 ^ $1 }) == message)
        // 使い捨ての鍵を決めなければ、毎回違う暗号文になる
        let first = try SealedBox.seal(message, to: recipient.publicKey.rawRepresentation)
        let second = try SealedBox.seal(message, to: recipient.publicKey.rawRepresentation)
        #expect(first != second)
    }

    @Test func refusesMalformedPublicKey() {
        #expect(throws: SealedBox.Failure.invalidPublicKey) { try SealedBox.seal(Data("x".utf8), to: Data(repeating: 1, count: 31)) }
    }
}
