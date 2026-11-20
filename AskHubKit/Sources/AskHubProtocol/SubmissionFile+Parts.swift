import Foundation

// `SubmissionFile` の、掲載文の案・App Store Connect の版の枠・配信した後の取り込みの形

extension SubmissionFile {
    /// 掲載文の案（Claude が、配信中の版の掲載文と前に配信した版からの変更をもとに、言語ごとに書いたもの）
    public struct Listing: Codable, Equatable, Sendable {
        /// 配信中の版の掲載文（言語ごと。人が見比べ、直すときの元にする）。空なら初めての版で、案を書かない
        public var current: [ListingText]
        /// 直す案（変える言語だけ。nil の欄は変えない）。空なら「変えない」
        public var drafts: [ListingText]
        /// 案の理由（変えないなら、その理由）。人が読む
        public var reason: String
        public var draftedAt: Timestamp

        public init(current: [ListingText], drafts: [ListingText], reason: String, draftedAt: Timestamp) {
            self.current = current
            self.drafts = drafts
            self.reason = reason
            self.draftedAt = draftedAt
        }

        /// 理由の長さの上限（Unicode のコードポイント）
        public static let reasonLimit = 1_000

        /// 合わない点（言語・長さ・案の言語が今の文に無い）
        public static func problems(of listing: Listing, name: String) -> [String] {
            var problems = ListingText.localeProblems(of: listing.current, name: "\(name) の current")
            problems += ListingText.problems(of: listing.drafts, name: "\(name) の drafts")
            let locales = Set(listing.current.map(\.locale))
            if listing.drafts.contains(where: { !locales.contains($0.locale) }) {
                problems.append("\(name) の drafts に、今の文に無い言語がある")
            }
            let reason = listing.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.isEmpty || listing.reason.unicodeScalars.count > reasonLimit {
                problems.append("\(name) の reason は 1〜\(reasonLimit) 文字")
            }
            return problems
        }
    }

    /// やめたリリースの版の枠を消した結果
    public enum SlotRemoval: String, Codable, Sendable, CaseIterable {
        /// 消した（すでに無かったときも）
        case deleted
        /// 消さなかった（審査に出ている・API で消せない）。理由は `removalNote`
        case kept
    }

    /// App Store Connect の版の枠（リリースを始めたときに、プラットフォームごとに作る・見つけた編集できる版）
    public struct VersionSlot: Codable, Equatable, Sendable {
        public var platform: AppStorePlatform
        /// App Store Connect の版の id
        public var id: String
        /// 枠に選んだビルドの番号。まだ選んでいなければ nil
        public var build: String?
        /// What's New の下書きを枠の各言語に書いた
        public var whatsNew: Bool
        public var at: Timestamp
        /// やめたリリースの枠を消した結果。まだなら nil
        public var removal: SlotRemoval?
        public var removalNote: String?

        public init(
            platform: AppStorePlatform,
            id: String,
            build: String? = nil,
            whatsNew: Bool = false,
            at: Timestamp,
            removal: SlotRemoval? = nil,
            removalNote: String? = nil
        ) {
            self.platform = platform
            self.id = id
            self.build = build
            self.whatsNew = whatsNew
            self.at = at
            self.removal = removal
            self.removalNote = removalNote
        }

        /// App Store Connect の資源の id の形（英数字と `-`。パスに入れる）
        public static func isID(_ text: String) -> Bool {
            (1...64).contains(text.utf8.count) && text.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || byte == UInt8(ascii: "-")
            }
        }
    }

    public enum IntegrationState: String, Codable, Sendable, CaseIterable {
        /// 取り込む PR を開いている（CI を待っている）
        case open
        /// PR をマージした
        case merged
        /// 取り込むコミットが無かった（release ブランチに直しが入っていない）
        case skipped
        /// 取り込む先のブランチ（main）が無かったので、release ブランチの先頭から作った
        case created
    }

    /// 配信した後に release ブランチを取り込む先（main と develop）の 1 つ
    public struct Integration: Codable, Equatable, Sendable {
        /// 取り込む先のブランチ（`main`・base の `develop`）
        public var base: String
        public var state: IntegrationState
        /// 取り込む PR の番号（`open`・`merged` のときだけ）
        public var pullRequest: Int?
        public var at: Timestamp

        public init(base: String, state: IntegrationState, pullRequest: Int? = nil, at: Timestamp) {
            self.base = base
            self.state = state
            self.pullRequest = pullRequest
            self.at = at
        }

        /// 終わった（マージした・取り込むものが無かった・作った）
        public var isDone: Bool { state != .open }
    }
}
