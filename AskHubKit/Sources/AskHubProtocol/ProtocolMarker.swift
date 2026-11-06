import CryptoKit
import Foundation

/// 各リポジトリのコメントや本文に置く目印（`docs/renewal/protocol.md` の「各リポジトリに書く目印」）。
///
/// 形は `<!-- askhub v1 {…} -->` の 1 行で、コメントの本文の最後の行に 1 つだけ置く。
/// 引用（`> …`）の中や、最後の行でない場所にある目印は読まない。
public enum ProtocolMarker {
    public static let prefix = "<!-- askhub v1 "
    public static let suffix = " -->"

    public struct Parsed: Equatable, Sendable {
        /// 目印の前の、人が読む本文（改行を `\n` にそろえ、末尾の空白と改行を除いたもの）
        public let body: String
        /// 目印の中の JSON（オブジェクト）
        public let value: JSONValue
    }

    /// 目印の 1 行を作る。中の JSON に `-->` が現れないよう、`>` は `>` に置き換える
    public static func line(for value: JSONValue) -> String {
        let json = CanonicalJSON.string(for: value).replacingOccurrences(of: ">", with: "\\u003e")
        return prefix + json + suffix
    }

    /// 本文の後に目印を置いたテキストを作る
    public static func text(body: String, marker value: JSONValue) -> String {
        let body = normalized(body)
        return body.isEmpty ? line(for: value) : body + "\n\n" + line(for: value)
    }

    /// テキストの最後の行から目印を読む。最後の行が目印でない・中の JSON がオブジェクトでなければ `nil`
    public static func parse(_ text: String) -> Parsed? {
        let text = normalized(text)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.last, last.hasPrefix(prefix), last.hasSuffix(suffix),
              last.count > prefix.count + suffix.count else {
            return nil
        }
        let json = last.dropFirst(prefix.count).dropLast(suffix.count)
        guard let value = try? JSONValue(parsing: String(json)), case .object = value else { return nil }
        let body = normalized(lines.dropLast().joined(separator: "\n"))
        return Parsed(body: body, value: value)
    }

    /// 本文のハッシュ（人の意図の封筒の `bodySha256`）。改行を `\n` にそろえ、末尾の空白と改行を除いた UTF-8 の SHA-256 を 16 進の小文字で表す
    public static func bodySHA256(_ body: String) -> String {
        SHA256.hash(data: Data(normalized(body).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 改行を `\n` にそろえ、末尾の空白と改行を除く（GitHub が改行を `\r\n` にして返すことがあるため）
    static func normalized(_ text: String) -> String {
        var text = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        while let last = text.unicodeScalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            text.unicodeScalars.removeLast()
        }
        return text
    }
}
