import Foundation

/// 仮決め一覧（`decision-log` の Issue）の本文の、チェックで始まる 1 行。
///
/// ```text
/// - [ ] #<PR番号> <判断の対象> → 採用: <値>（別案: <案1> / <案2>）
/// ```
///
/// 詳細は `docs/protocol.md` の「仮決めの行の形式」を参照。
/// 形式に合わない行も、チェックで始まるものは `decision` が `nil` の項目として残す（本文のまま出すため）。
/// 読み取りは表示のためだけに使い、本文の書き換えでは `text` との全文一致で行を探す。
public struct DecisionLogItem: Sendable, Equatable {
    /// チェックが付いているか（`- [x]` / `- [X]`）
    public let isChecked: Bool
    /// チェックの後ろの文字列（前後の空白は除く）
    public let text: String
    /// 形式に合う行から読み取った中身。形式に合わなければ `nil`
    public let decision: Decision?

    public init(isChecked: Bool, text: String, decision: Decision?) {
        self.isChecked = isChecked
        self.text = text
        self.decision = decision
    }

    /// 形式に合う行の中身
    public struct Decision: Sendable, Equatable {
        /// 仮決めをした PR の番号
        public let pullRequest: Int
        /// 判断の対象
        public let subject: String
        /// 採用した値
        public let adopted: String
        /// 別案。`（別案: …）` が無ければ空
        public let alternatives: [String]
        /// ループが指示を受けて追記した ` → 変更: ` の後ろ。追記が無ければ `nil`
        public let change: String?

        public init(pullRequest: Int, subject: String, adopted: String, alternatives: [String], change: String?) {
            self.pullRequest = pullRequest
            self.subject = subject
            self.adopted = adopted
            self.alternatives = alternatives
            self.change = change
        }
    }

    private static let uncheckedPrefix = "- [ ]"
    private static let checkedPrefixes = ["- [x]", "- [X]"]
    private static let adoptedSeparator = " → 採用: "
    private static let changeSeparator = " → 変更: "
    private static let alternativesOpen = "（別案: "
    private static let alternativesClose = "）"
    private static let alternativesSeparator = " / "

    /// 本文からチェックで始まる行を上から順に読む。チェックで始まらない行（冒頭の説明など）は含めない
    public static func items(in body: String) -> [Self] {
        body.split(whereSeparator: \.isNewline).compactMap { parse(line: String($0)) }
    }

    /// 1 行を読む。チェックで始まらなければ `nil`
    public static func parse(line: String) -> Self? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let isChecked: Bool
        let rest: Substring
        if trimmed.hasPrefix(uncheckedPrefix) {
            isChecked = false
            rest = trimmed.dropFirst(uncheckedPrefix.count)
        } else if let prefix = checkedPrefixes.first(where: { trimmed.hasPrefix($0) }) {
            isChecked = true
            rest = trimmed.dropFirst(prefix.count)
        } else {
            return nil
        }
        let text = rest.trimmingCharacters(in: .whitespaces)
        return Self(isChecked: isChecked, text: text, decision: decision(in: text))
    }

    private static func decision(in text: String) -> Decision? {
        guard let match = text.wholeMatch(of: /#(\d+) (.+)/),
              let pullRequest = Int(match.1),
              let adoptedRange = match.2.range(of: adoptedSeparator) else {
            return nil
        }
        let subject = match.2[..<adoptedRange.lowerBound].trimmingCharacters(in: .whitespaces)
        var body = match.2[adoptedRange.upperBound...]
        var change: String?
        // ループは行の末尾に追記するので、採用の値に同じ文字列があっても最後の区切りで分ける
        if let changeRange = body.range(of: changeSeparator, options: .backwards) {
            change = body[changeRange.upperBound...].trimmingCharacters(in: .whitespaces)
            body = body[..<changeRange.lowerBound]
        }
        var adopted = body.trimmingCharacters(in: .whitespaces)
        var alternatives: [String] = []
        if adopted.hasSuffix(alternativesClose),
           let openRange = adopted.range(of: alternativesOpen, options: .backwards) {
            alternatives = adopted[openRange.upperBound..<adopted.index(before: adopted.endIndex)]
                .components(separatedBy: alternativesSeparator)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            // 空の別案があると番号（別案 N）がずれるので、形式に合わない行として扱う
            guard !alternatives.contains(where: \.isEmpty) else {
                return nil
            }
            adopted = adopted[..<openRange.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        guard !subject.isEmpty, !adopted.isEmpty else {
            return nil
        }
        return Decision(pullRequest: pullRequest, subject: subject, adopted: adopted, alternatives: alternatives, change: change)
    }
}
