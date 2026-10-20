import Foundation

/// `AppStore/metadata/<言語>.json` の `whatsNew`（`{"version": "1.1.0", "text": "…"}`）。確定した最新情報
public struct ConfirmedWhatsNew: Sendable, Equatable, Decodable {
    /// 反映先のバージョン。リリースのバージョンと同じなら、そのリリースの最新情報は確定済み
    public var version: String
    public var text: String

    public init(version: String, text: String) {
        self.version = version
        self.text = text
    }
}

/// リリースの最新情報が、下書きのままか確定済みか（Discussion #605 の Q5）
public struct ReleaseNotes: Sendable, Equatable {
    public enum Status: Sendable, Equatable {
        /// 下書きがある（未確定）。人が確かめて確定する
        case draft(WhatsNewDraft)
        /// 下書きのファイルはあるが、知らない形の版（`schemaVersion`）なので読まなかった。アプリを新しくするよう知らせる
        case unsupportedDraft(schemaVersion: Int)
        /// 下書きが無く、`languages` のすべての言語の `whatsNew.version` がリリースのバージョン
        case confirmed
        /// 下書きも確定した最新情報も無い（一部の言語だけ確定しているときも含む）。リリース準備の途中か、下書きを作れなかった
        case missing
    }

    public var version: ReleaseVersion
    public var status: Status
    /// App Store に載せる言語（`AppStore/languages.json` の `language`）
    public var languages: [String]
    /// 言語ごとの `whatsNew`（バージョンが違う＝前のリリースのものも含む。ファイルや `whatsNew` が無い言語は入らない）
    public var whatsNew: [String: ConfirmedWhatsNew]

    public init(version: ReleaseVersion, status: Status, languages: [String], whatsNew: [String: ConfirmedWhatsNew]) {
        self.version = version
        self.status = status
        self.languages = languages
        self.whatsNew = whatsNew
    }

    /// 言語ごとの、このリリースのバージョンで確定した本文
    public var confirmedTexts: [String: String] {
        whatsNew.filter { $0.value.version == version.description }.mapValues(\.text)
    }

    /// 下書きが無いときの状態。`languages` のすべての言語でリリースのバージョンの `whatsNew` があれば確定済み
    /// （下書きがあれば、`whatsNew` に関係なく未確定とみなす。確定すると下書きは消えるため）
    public static func statusWithoutDraft(languages: [String], whatsNew: [String: ConfirmedWhatsNew], version: ReleaseVersion) -> Status {
        let confirmed = !languages.isEmpty && languages.allSatisfy { whatsNew[$0]?.version == version.description }
        return confirmed ? .confirmed : .missing
    }
}
