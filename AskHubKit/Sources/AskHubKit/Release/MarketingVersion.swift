import Foundation

/// `Configs/Project.xcconfig` の `MARKETING_VERSION`。アプリの「リリース準備」のバージョンの既定値（次のマイナー）の元にする（Discussion #605 の Q2）
public struct MarketingVersion: Sendable, Hashable {
    /// xcconfig に書かれた値（前後の空白を除く）
    public var raw: String
    /// `raw` を `MAJOR.MINOR.PATCH` として読んだもの。`1.0` や `$(…)` のように形が違えば `nil`
    public var version: ReleaseVersion?

    public init(raw: String) {
        self.raw = raw
        version = ReleaseVersion(raw)
    }

    /// 次のマイナー（`1.0.0` → `1.1.0`）。値の形が違えば `nil`（アプリは既定値を入れず、人に入力してもらう）
    public var nextMinor: ReleaseVersion? {
        version?.nextMinor
    }

    /// xcconfig の本文から `MARKETING_VERSION` を読む。無ければ `nil`。
    ///
    /// - `//` から行末まではコメントとして外す。行末の `;` も外す
    /// - `MARKETING_VERSION[sdk=…]` のような条件付きの設定は読まない
    /// - 同じキーが何度もあれば、xcconfig と同じく最後のものを使う
    public static func parse(xcconfig: String) -> Self? {
        var value: String?
        for line in xcconfig.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var text = Substring(line)
            if let comment = text.range(of: "//") {
                text = text[..<comment.lowerBound]
            }
            guard let equals = text.firstIndex(of: "=") else {
                continue
            }
            let key = text[..<equals].trimmingCharacters(in: .whitespaces)
            guard key == "MARKETING_VERSION" else {
                continue
            }
            var rawValue = text[text.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if rawValue.hasSuffix(";") {
                rawValue = String(rawValue.dropLast()).trimmingCharacters(in: .whitespaces)
            }
            value = rawValue
        }
        return value.map(Self.init(raw:))
    }
}
