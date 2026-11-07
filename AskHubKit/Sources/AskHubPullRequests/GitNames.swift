/// URL のパスや問い合わせに入れる前に、ブランチ名と SHA の形を確かめる（ワーカーが作るものだけを扱う）
enum GitNames {
    /// ブランチ名: 英数字と `._-/` で 1〜255 文字。`/` で始まり・終わらず、`//`・`..`・`.lock` の終わりを含まない
    static func checkBranch(_ name: String) throws(PullRequestError) {
        let allowed = name.utf8.allSatisfy { byte in
            isAlphanumeric(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "/")
        }
        let shaped = !name.hasPrefix("/") && !name.hasSuffix("/") && !name.hasPrefix("-") && !name.hasSuffix(".lock")
            && !name.contains("//") && !name.contains("..")
        guard (1...255).contains(name.utf8.count), allowed, shaped else { throw .invalidArgument("ブランチ名の形が違う") }
    }

    /// コミットの SHA: 16 進の小文字で 40 文字（SHA-1）か 64 文字（SHA-256）
    static func checkSHA(_ sha: String) throws(PullRequestError) {
        let isHex = sha.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
        guard sha.utf8.count == 40 || sha.utf8.count == 64, isHex else { throw .invalidArgument("SHA の形が違う") }
    }

    /// PR・run の番号: 1 以上
    static func checkNumber(_ number: Int) throws(PullRequestError) {
        guard number > 0 else { throw .invalidArgument("番号が 1 より小さい") }
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
            || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
    }
}
