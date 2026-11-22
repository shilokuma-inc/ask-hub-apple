import Foundation

// `SubmissionFile` の、審査に出す中身・掲載文と App Review の情報の案・App Store Connect の版の枠・配信した後の取り込みの形

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

    /// 人が「審査に出す」を押した中身（`submitForReview`）。司令塔が App Store Connect に出し終えたら、`review` に `submittedAt` が付く
    public struct Submit: Codable, Equatable, Sendable {
        public var approval: IntentReference
        public var at: Timestamp
        public var builds: [BuildChoice]
        /// 人が確かめた What's New（言語ごと）
        public var whatsNew: [LocalizedText]
        public var releaseType: AppStoreReleaseType
        /// `scheduled` のときの配信の日時（これより前には配信しない）
        public var earliestReleaseDate: Timestamp?
        /// 人が確かめた掲載文の直し（変える言語だけ。nil の欄は変えない）。nil は掲載文を扱う前に受け付けたもの
        public var listing: [ListingText]?
        /// 人が確かめた App Review の情報の直し（nil の欄は変えない）。nil なら変えない
        public var appReview: ReviewInformation?
        /// 人が確かめたスクショ（前のままにする画面）。nil ならスクショを変えない
        public var screenshots: ScreenshotDecision?
        /// 載せるクリエイティブアセット（人が承認した案の版）。nil なら載せない
        public var creative: CreativeChoice?

        public init(
            approval: IntentReference,
            at: Timestamp,
            builds: [BuildChoice],
            whatsNew: [LocalizedText],
            releaseType: AppStoreReleaseType,
            earliestReleaseDate: Timestamp? = nil,
            listing: [ListingText]? = nil,
            appReview: ReviewInformation? = nil,
            screenshots: ScreenshotDecision? = nil,
            creative: CreativeChoice? = nil
        ) {
            self.approval = approval
            self.at = at
            self.builds = builds
            self.whatsNew = whatsNew
            self.releaseType = releaseType
            self.earliestReleaseDate = earliestReleaseDate
            self.listing = listing
            self.appReview = appReview
            self.screenshots = screenshots
            self.creative = creative
        }
    }

    /// 審査に出すときに載せるクリエイティブアセット（`creative.json` の `approved` の案の版）
    public struct CreativeChoice: Codable, Equatable, Sendable {
        public var revision: Int

        public init(revision: Int) {
            self.revision = revision
        }
    }

    /// App Review の情報の案（掲載文の案と同じ Claude の下書きで書く）
    public struct AppReview: Codable, Equatable, Sendable {
        /// 配信中の版の App Review の情報（パスワード・連絡先は持たない）
        public var current: ReviewInformation
        /// 直す案（nil の欄は変えない）。nil なら変えない
        public var draft: ReviewInformation?
        /// 案の理由（変えないなら、その理由）。人が読む
        public var reason: String
        public var draftedAt: Timestamp

        public init(current: ReviewInformation, draft: ReviewInformation?, reason: String, draftedAt: Timestamp) {
            self.current = current
            self.draft = draft
            self.reason = reason
            self.draftedAt = draftedAt
        }

        /// 合わない点（長さ・変える欄の無い案・理由）
        public static func problems(of review: AppReview, name: String) -> [String] {
            var problems = ReviewInformation.problems(of: review.current, name: "\(name) の current")
            if let draft = review.draft {
                problems += ReviewInformation.problems(of: draft, name: "\(name) の draft")
                if draft.isEmpty { problems.append("\(name) の draft に変える欄が無い") }
            }
            let reason = review.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            if reason.isEmpty || review.reason.unicodeScalars.count > Listing.reasonLimit {
                problems.append("\(name) の reason は 1〜\(Listing.reasonLimit) 文字")
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

extension SubmissionFile {
    /// やめたリリースの、まだ消していない版の枠がある
    public var awaitsSlotRemoval: Bool {
        end?.reason == .abandoned && (appStoreVersions ?? []).contains { $0.removal == nil }
    }

    /// 配信した後に、release ブランチを main と develop に取り込むのを待っている（取り込む先がすべて終わるまで見回る）
    public func awaitsIntegration(bases: [String]) -> Bool {
        guard end?.reason == .distributed, branch != nil else { return false }
        return bases.contains { base in !(integration ?? []).contains { $0.base == base && $0.isDone } }
    }
}
