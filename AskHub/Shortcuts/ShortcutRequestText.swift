import AskHubProtocol
import Foundation

/// Siri・ショートカットで受け取った依頼の文を、要約（epic の名前）と依頼の内容に分けたもの（Issue #1122 で決めた形）。
///
/// - 1 行目を要約、2 行目以降を依頼の内容にする。声の 1 文なら要約だけになる
/// - 1 行目が要約の上限より長ければ、要約は切り詰めて「…」で終え、依頼の文の全体を内容に入れる（言ったことを落とさない）
nonisolated struct ShortcutRequestText: Equatable {
    let summary: String
    let body: String

    /// 空白と改行だけなら nil（Siri に聞き直させる）
    init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        // "\r\n" は 1 つの Character なので、`isNewline` で区切る
        let lines = trimmed.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let firstLine = lines[0].trimmingCharacters(in: .whitespaces)
        let rest = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // 司令塔は要約の長さを Unicode のスカラーの数で数える（`RequestIntent` の `title`）
        if firstLine.unicodeScalars.count <= RequestIntent.maximumTitleLength {
            summary = firstLine
            body = rest
        } else {
            summary = Self.truncated(firstLine, toScalars: RequestIntent.maximumTitleLength)
            body = trimmed
        }
    }

    /// 末尾を「…」にして、スカラーの数を上限に収める。文字（絵文字の結合など）の途中では切らない
    private static func truncated(_ text: String, toScalars limit: Int) -> String {
        let ellipsis = "…"
        var result = ""
        var count = 0
        for character in text {
            let scalars = character.unicodeScalars.count
            guard count + scalars + ellipsis.unicodeScalars.count <= limit else {
                break
            }
            result.append(character)
            count += scalars
        }
        return result.trimmingCharacters(in: .whitespaces) + ellipsis
    }
}
