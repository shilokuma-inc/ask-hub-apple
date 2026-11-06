import Foundation

/// 対象のリポジトリの事実（Claude の決まりの文に入れて渡す）を、CLAUDE.md から取り出す。
///
/// `## 全員向けの事実` の見出しがあればその節だけを、無ければ CLAUDE.md 全体を渡す（ユーザーの決定）。
/// 人のセッション向けの手順は、その見出しの外に書けば渡らない
public enum RepositoryFacts {
    /// 全員向けの事実の節の見出し（2 段目）
    public static let heading = "全員向けの事実"
    /// 渡す長さの上限（文字数）。超えた分は省く
    public static let maximumLength = 16_000

    public static func extract(from text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        let facts = section(in: lines) ?? lines
        return capped(facts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `## 全員向けの事実` の節。次の同じか上の段の見出しの前まで（コードブロックの中の `#` は見出しとみなさない）
    private static func section(in lines: [String]) -> [String]? {
        var fence: Fence?
        var start: Int?
        for (index, line) in lines.enumerated() {
            if let open = fence {
                if open.isClosed(by: line) { fence = nil }
                continue
            }
            if let opening = Fence(opening: line) {
                fence = opening
                continue
            }
            guard let level = headingLevel(of: line) else { continue }
            if let start {
                if level <= 2 { return Array(lines[(start + 1)..<index]) }
            } else if level == 2, title(of: line) == heading {
                start = index
            }
        }
        return start.map { Array(lines[($0 + 1)...]) }
    }

    /// コードブロックの囲み（CommonMark: 3 つ以上の ``` か ~~~。同じ文字で、開きと同じか長い並びで閉じる）
    private struct Fence {
        let character: Character
        let length: Int

        init?(opening line: String) {
            let trimmed = Self.indented(line)
            guard let first = trimmed?.first, first == "`" || first == "~", let trimmed else { return nil }
            let length = trimmed.prefix { $0 == first }.count
            guard length >= 3 else { return nil }
            character = first
            self.length = length
        }

        func isClosed(by line: String) -> Bool {
            guard let trimmed = Self.indented(line) else { return false }
            let length = trimmed.prefix { $0 == character }.count
            return length >= self.length && trimmed.dropFirst(length).allSatisfy(\.isWhitespace)
        }

        /// 先頭の空白（3 つまで）を除いた行。4 つ以上ならインデントのコードなので nil
        static func indented(_ line: String) -> Substring? {
            let spaces = line.prefix { $0 == " " }.count
            return spaces <= 3 ? line.dropFirst(spaces) : nil
        }
    }

    /// ATX の見出しの段（先頭の空白は 3 つまで）。見出しでなければ nil
    private static func headingLevel(of line: String) -> Int? {
        guard let trimmed = Fence.indented(line) else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        return hashes
    }

    /// 見出しの文（閉じの `#` の並びを除く）
    private static func title(of line: String) -> String {
        var text = (Fence.indented(line) ?? Substring(line)).drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        if let closing = text.lastIndex(where: { $0 != "#" }), text[text.index(after: closing)...].allSatisfy({ $0 == "#" }),
           text.index(after: closing) != text.endIndex, text[closing] == " " {
            text = String(text[..<closing]).trimmingCharacters(in: .whitespaces)
        } else if text.allSatisfy({ $0 == "#" }) {
            text = ""
        }
        return text
    }

    private static func capped(_ text: String) -> String {
        guard text.count > maximumLength else { return text }
        return String(text.prefix(maximumLength)) + "\n…（長いので、ここから先は省いた）"
    }
}
