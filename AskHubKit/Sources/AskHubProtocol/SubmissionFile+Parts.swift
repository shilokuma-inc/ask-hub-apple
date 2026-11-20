import Foundation

// `SubmissionFile` の、App Store Connect の版の枠と配信した後の取り込みの形

extension SubmissionFile {
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
