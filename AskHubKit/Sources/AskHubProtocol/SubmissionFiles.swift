import Foundation

/// App Store の 1 つの言語の文（What's New など）。`locale` は App Store Connect の言語（`ja`・`en-US`・`zh-Hans` など）
public struct LocalizedText: Codable, Hashable, Sendable {
    public var locale: String
    public var text: String

    public init(locale: String, text: String) {
        self.locale = locale
        self.text = text
    }

    /// What's New の長さの上限（Unicode のコードポイント。App Store Connect の上限）
    public static let whatsNewLimit = 4_000
    /// 1 つの版に持てる言語の数の上限（App Store の言語の数より十分に大きい）
    public static let localeLimit = 50

    /// App Store Connect の言語の形（英小文字 2〜3 字に、`-` で英数字 2〜8 字を 2 つまでつないだもの）
    public static func isLocale(_ text: String) -> Bool {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), let language = parts.first,
              (2...3).contains(language.utf8.count),
              language.utf8.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) }) else {
            return false
        }
        return parts.dropFirst().allSatisfy { part in
            (2...8).contains(part.utf8.count) && part.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
            }
        }
    }

    /// What's New の並びの合わない点（言語の形・重なり・空の文・長さ）
    public static func problems(of texts: [LocalizedText], name: String) -> [String] {
        var problems: [String] = []
        if texts.count > localeLimit { problems.append("\(name) の言語が \(localeLimit) を超えている") }
        if Set(texts.map(\.locale)).count != texts.count { problems.append("\(name) の言語が重複している") }
        if texts.contains(where: { !isLocale($0.locale) }) { problems.append("\(name) の locale の形が違う") }
        if texts.contains(where: { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            problems.append("\(name) の text が空")
        }
        if texts.contains(where: { $0.text.unicodeScalars.count > whatsNewLimit }) {
            problems.append("\(name) の text が \(whatsNewLimit) 文字を超えている")
        }
        return problems
    }
}

/// 審査に通った後の配信の方式（App Store Connect の `releaseType`）
public enum AppStoreReleaseType: String, Codable, Sendable, CaseIterable {
    /// 承認されたらすぐ配信する（既定）
    case afterApproval
    /// 承認された後、人が「配信する」を押したときに配信する（`distributeRelease`）
    case manual
    /// 承認された後、決めた日時より後に配信する
    case scheduled

    public var appStoreConnectValue: String {
        switch self {
        case .afterApproval: "AFTER_APPROVAL"
        case .manual: "MANUAL"
        case .scheduled: "SCHEDULED"
        }
    }
}

/// App Store の版の状態（App Store Connect の `appVersionState`）
public enum AppStoreVersionState: String, Codable, Sendable, CaseIterable {
    case prepareForSubmission
    case readyForReview
    case waitingForReview
    case inReview
    case pendingDeveloperRelease
    case pendingAppleRelease
    case processingForDistribution
    case readyForDistribution
    case rejected
    case metadataRejected
    case developerRejected
    case accepted
    case invalidBinary
    case waitingForExportCompliance
    case replacedWithNewVersion

    /// App Store Connect の API の値（`IN_REVIEW` など）
    public var appStoreConnectValue: String {
        rawValue.reduce(into: "") { result, character in
            if character.isUppercase { result += "_" }
            result += character.uppercased()
        }
    }

    public init?(appStoreConnectValue: String) {
        guard let state = Self.allCases.first(where: { $0.appStoreConnectValue == appStoreConnectValue }) else { return nil }
        self = state
    }

    /// 審査を待っている・審査中（取り下げられる）
    public var isUnderReview: Bool { self == .waitingForReview || self == .inReview }

    /// 審査に通った（配信を待っている・配信の処理中）
    public var isApproved: Bool {
        [.pendingDeveloperRelease, .pendingAppleRelease, .processingForDistribution, .accepted].contains(self)
    }

    /// 審査で断られた（理由を App Store Connect で確かめる）
    public var isRejected: Bool { [.rejected, .metadataRejected, .invalidBinary].contains(self) }

    /// 審査に出してから配信までの間（この間は、やめる・審査に出し直すを受け付けない）
    public var isInFlight: Bool { isUnderReview || isApproved || self == .readyForDistribution || self == .waitingForExportCompliance }
}

/// `repos/<owner>/<repo>/submissions/<版>.json`（リリースを始めた版の準備と審査）。司令塔だけが書く。
///
/// 人が「リリースを始める」（`startRelease`）を押したときに作り、release ブランチ・develop の版を上げる PR・What's New の下書き・
/// release ブランチから上げたビルドを足していく。人が確かめて「審査に出す」（`submitForReview`）を押すと、司令塔が App Store Connect に出し、
/// 審査の状態をプラットフォームごとに書く。App Store Connect の Web で手で出した版も、審査を待っている・審査中などを見つけたら作る
/// （`origin` が `appStoreConnect`）。配信を見つけたら終わりの印を付け、その後作業は `releases/<版>.json` で進める
/// （`docs/renewal/release.md` の「リリースを始めてから配信まで」）
public struct SubmissionFile: StateFile {
    public static let formatVersion = 1

    /// 記録を作ったきっかけ
    public enum Origin: String, Codable, Sendable, CaseIterable {
        /// 人が AskHub で「リリースを始める」を押した
        case askhub
        /// App Store Connect で、手で審査に出した版を見つけた（準備の欄を持たない）
        case appStoreConnect
    }

    /// 人の意図と、それを受け付けた時刻
    public struct Approval: Codable, Equatable, Sendable {
        public var approval: IntentReference
        public var at: Timestamp

        public init(approval: IntentReference, at: Timestamp) {
            self.approval = approval
            self.at = at
        }
    }

    /// release ブランチ（`release/<版>`）
    public struct Branch: Codable, Equatable, Sendable {
        public var name: String
        /// 作ったときの先頭（develop の先頭）
        public var commit: String
        /// 司令塔が作ったなら true。前からあったなら false
        public var created: Bool
        public var at: Timestamp

        public init(name: String, commit: String, created: Bool, at: Timestamp) {
            self.name = name
            self.commit = commit
            self.created = created
            self.at = at
        }
    }

    /// release ブランチから上げたビルド（プラットフォームごとに、処理を終えた最新のもの）
    public struct Build: Codable, Equatable, Sendable {
        public var platform: AppStorePlatform
        /// ビルドの番号（`CFBundleVersion`）
        public var build: String
        public var uploadedAt: Timestamp?

        public init(platform: AppStorePlatform, build: String, uploadedAt: Timestamp? = nil) {
            self.platform = platform
            self.build = build
            self.uploadedAt = uploadedAt
        }
    }

    /// What's New の下書き（Claude が言語ごとに書いたもの）
    public struct WhatsNew: Codable, Equatable, Sendable {
        /// 言語ごとの下書き。空なら、App Store にまだ版が無い（初めての版は What's New を持たない）
        public var drafts: [LocalizedText]
        public var draftedAt: Timestamp

        public init(drafts: [LocalizedText], draftedAt: Timestamp) {
            self.drafts = drafts
            self.draftedAt = draftedAt
        }
    }

    /// 審査に出すビルドの 1 つ
    public struct BuildChoice: Codable, Hashable, Sendable {
        public var platform: AppStorePlatform
        public var build: String

        public init(platform: AppStorePlatform, build: String) {
            self.platform = platform
            self.build = build
        }
    }

    /// 1 つのプラットフォームの審査の状態（司令塔が App Store Connect で読んだもの）
    public struct Review: Codable, Equatable, Sendable {
        public var platform: AppStorePlatform
        public var state: AppStoreVersionState
        /// 今の状態になったのを読んだ時刻
        public var since: Timestamp
        /// 司令塔が審査に出した時刻（手で出した版・まだ出していない版は nil）
        public var submittedAt: Timestamp?

        public init(platform: AppStorePlatform, state: AppStoreVersionState, since: Timestamp, submittedAt: Timestamp? = nil) {
            self.platform = platform
            self.state = state
            self.since = since
            self.submittedAt = submittedAt
        }
    }

    /// 人が押した操作（配信する・審査の取り下げ）。司令塔が App Store Connect に送ったら `doneAt` が付く
    public struct Request: Codable, Equatable, Sendable {
        public var approval: IntentReference
        public var at: Timestamp
        public var doneAt: Timestamp?

        public init(approval: IntentReference, at: Timestamp, doneAt: Timestamp? = nil) {
            self.approval = approval
            self.at = at
            self.doneAt = doneAt
        }
    }

    public enum EndReason: String, Codable, Sendable, CaseIterable {
        /// 配信を見つけた（後作業は `releases/<版>.json`）
        case distributed
        /// 人がやめた（`abandonRelease`）
        case abandoned
        /// もっと新しい版を配信した
        case superseded
    }

    public struct End: Codable, Equatable, Sendable {
        public var reason: EndReason
        public var at: Timestamp
        /// やめた人の意図（`abandoned` のときだけ）
        public var approval: IntentReference?

        public init(reason: EndReason, at: Timestamp, approval: IntentReference? = nil) {
            self.reason = reason
            self.at = at
            self.approval = approval
        }
    }

    /// 進めることの区切り
    public enum Step: String, Codable, Sendable, CaseIterable {
        case branch
        case nextVersion
        case whatsNew
        case builds
        case submit
        case distribute
        case withdraw
        case review
        case integration
        case appStoreVersion
        case listing
        case screenshots
    }

    /// 進められなかった理由（進められたら消す）
    public struct Problem: Codable, Equatable, Sendable {
        public var step: Step
        public var message: String
        /// 人が手で直す必要がある（やり直しても進まない）なら true
        public var needsHuman: Bool
        public var at: Timestamp

        public init(step: Step, message: String, needsHuman: Bool, at: Timestamp) {
            self.step = step
            self.message = message
            self.needsHuman = needsHuman
            self.at = at
        }
    }

    public var repo: RepositoryFullName
    public var version: MarketingVersion
    public var origin: Origin
    /// リリースを始めた人の意図（`askhub` のときだけ）
    public var start: Approval?
    public var branch: Branch?
    /// develop の `MARKETING_VERSION` を次の版に上げる PR（配信の後作業と同じ形）
    public var nextVersion: ReleaseFile.NextVersion?
    public var builds: [Build]
    public var whatsNew: WhatsNew?
    /// 掲載文（説明文・キーワード・プロモーションテキスト）の案
    public var listing: Listing?
    /// App Review の情報の案（掲載文の案と一緒に書く）。初めての版・App Review の情報を扱う前に書いた案は nil
    public var appReview: AppReview?
    /// App Store のスクショを撮って比べた結果。まだ撮り始めていなければ nil
    public var screenshots: StoreScreenshots?
    /// ビルド・What's New の下書き・掲載文の案が変わるたびに上げる。審査に出す人の意図の `targetVersion`（人が見たものを出す）
    public var revision: Int
    public var submit: Submit?
    public var review: [Review]
    public var distribution: Request?
    public var withdrawal: Request?
    /// 審査で断られたときの対処（断られた提出ごと。最後が今の対処）。断られていなければ nil
    public var rejections: [Rejection]?
    public var end: End?
    /// 配信した後に release ブランチを取り込んだ様子（main と develop）。release ブランチを作った版だけ
    public var integration: [Integration]?
    /// App Store Connect の版の枠。nil なら枠を作らない（この仕組みの前に始めた記録）。リリースを始めたときに空の並びで作り、司令塔が埋める
    public var appStoreVersions: [VersionSlot]?
    public var problem: Problem?
    public var createdAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        version: MarketingVersion,
        origin: Origin,
        start: Approval? = nil,
        branch: Branch? = nil,
        nextVersion: ReleaseFile.NextVersion? = nil,
        builds: [Build] = [],
        whatsNew: WhatsNew? = nil,
        listing: Listing? = nil,
        appReview: AppReview? = nil,
        screenshots: StoreScreenshots? = nil,
        revision: Int = 0,
        submit: Submit? = nil,
        review: [Review] = [],
        distribution: Request? = nil,
        withdrawal: Request? = nil,
        rejections: [Rejection]? = nil,
        end: End? = nil,
        integration: [Integration]? = nil,
        appStoreVersions: [VersionSlot]? = nil,
        problem: Problem? = nil,
        createdAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.repo = repo
        self.version = version
        self.origin = origin
        self.start = start
        self.branch = branch
        self.nextVersion = nextVersion
        self.builds = builds
        self.whatsNew = whatsNew
        self.listing = listing
        self.appReview = appReview
        self.screenshots = screenshots
        self.revision = revision
        self.submit = submit
        self.review = review
        self.distribution = distribution
        self.withdrawal = withdrawal
        self.rejections = rejections
        self.end = end
        self.integration = integration
        self.appStoreVersions = appStoreVersions
        self.problem = problem
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// release ブランチの名前（`release/<版>`）
    public static func branchName(for version: MarketingVersion) -> String { "release/\(version.rawValue)" }

    public var isEnded: Bool { end != nil }

    /// 審査に出す準備（What's New の下書き・掲載文の案・スクショの撮影と、release ブランチから上げたビルド）がそろった
    public var isPrepared: Bool {
        origin == .askhub && whatsNew != nil && listing != nil && screenshots?.state.isSettled == true && screenshots?.awaitsRetake != true
            && !builds.isEmpty
    }

    /// 審査に出してから配信までの間のプラットフォームがある
    public var hasReviewInFlight: Bool { review.contains { $0.state.isInFlight } }

    /// 審査に出すのを受け付けて、司令塔がまだ App Store Connect に出し終えていない
    public var isSubmitting: Bool {
        guard let submit else { return false }
        return submit.builds.contains { choice in
            !(review.first { $0.platform == choice.platform }?.submittedAt.map { $0 >= submit.at } ?? false)
        }
    }

    /// 人が What's New とビルドを確かめて「審査に出す」を押すのを待っている（「あなたの番」に出す）。
    /// リジェクトでコードを直すを選んだ後は、直した後に上げたビルドが見つかるまで待たない
    public var awaitsSubmission: Bool { !isEnded && isPrepared && submit == nil && !hasReviewInFlight && !awaitsFixedBuild }

    /// 審査に通り、人が「配信する」を押すのを待っている（配信の方式が手動）
    public var awaitsDistribution: Bool {
        !isEnded && distribution == nil && review.contains { $0.state == .pendingDeveloperRelease }
    }

    /// 審査を取り下げられる（審査を待っている・審査中で、取り下げを送っていない）
    public var canWithdraw: Bool {
        let sending = withdrawal.map { $0.doneAt == nil } ?? false
        return !isEnded && !sending && review.contains { $0.state.isUnderReview }
    }

    /// このリリースをやめられる（審査に出していない・取り下げた・断られた）
    public var canAbandon: Bool { !isEnded && !hasReviewInFlight && !isSubmitting }

    /// やめたリリースの、まだ消していない版の枠がある
    public var awaitsSlotRemoval: Bool {
        end?.reason == .abandoned && (appStoreVersions ?? []).contains { $0.removal == nil }
    }

    /// 配信した後に、release ブランチを main と develop に取り込むのを待っている（取り込む先がすべて終わるまで見回る）
    public func awaitsIntegration(bases: [String]) -> Bool {
        guard end?.reason == .distributed, branch != nil else { return false }
        return bases.contains { base in !(integration ?? []).contains { $0.base == base && $0.isDone } }
    }

    public var violations: [String] {
        var violations: [String] = []
        switch origin {
        case .askhub:
            if start == nil { violations.append("AskHub で始めた記録に start が無い") }
        case .appStoreConnect:
            if start != nil || branch != nil || nextVersion != nil || !builds.isEmpty
                || whatsNew != nil || listing != nil || appReview != nil || screenshots != nil || submit != nil {
                violations.append("手で出した版の記録は、準備の欄（start・branch・nextVersion・builds・whatsNew・listing・appReview・screenshots・submit）を持たない")
            }
        }
        if let branch {
            if branch.name != Self.branchName(for: version) { violations.append("branch の name が release/<版> でない") }
            if !ReleaseFile.isCommit(branch.commit) { violations.append("branch の commit が 40 桁の 16 進でない") }
        }
        if let nextVersion {
            switch nextVersion.state {
            case .open, .merged:
                if nextVersion.pullRequest.map({ $0 < 1 }) ?? true { violations.append("版を上げる PR の番号が無い") }
                if nextVersion.version <= version { violations.append("次の版が始めた版より大きくない") }
            case .skipped:
                if nextVersion.pullRequest != nil { violations.append("上げなかったときは PR を持たない") }
            }
        }
        if Set(builds.map(\.platform)).count != builds.count { violations.append("builds のプラットフォームが重複している") }
        if builds.contains(where: { !ReleaseFile.isBuildNumber($0.build) }) { violations.append("builds の build の形が違う") }
        if let whatsNew { violations += LocalizedText.problems(of: whatsNew.drafts, name: "whatsNew の drafts") }
        if let listing { violations += Listing.problems(of: listing, name: "listing") }
        if let appReview { violations += AppReview.problems(of: appReview, name: "appReview") }
        if let screenshots { violations += screenshots.problems }
        if revision < 0 { violations.append("revision は 0 以上") }
        if let submit {
            if submit.builds.isEmpty { violations.append("submit の builds が空") }
            if Set(submit.builds.map(\.platform)).count != submit.builds.count { violations.append("submit の builds のプラットフォームが重複している") }
            if submit.builds.contains(where: { !ReleaseFile.isBuildNumber($0.build) }) {
                violations.append("submit の builds の build の形が違う")
            }
            violations += LocalizedText.problems(of: submit.whatsNew, name: "submit の whatsNew")
            if let changes = submit.listing { violations += ListingText.problems(of: changes, name: "submit の listing") }
            if let decision = submit.screenshots { violations += decision.problems }
            if let change = submit.appReview {
                violations += ReviewInformation.problems(of: change, name: "submit の appReview")
                if change.isEmpty { violations.append("submit の appReview に変える欄が無い") }
            }
            if (submit.releaseType == .scheduled) != (submit.earliestReleaseDate != nil) {
                violations.append("earliestReleaseDate は、配信の方式が scheduled のときだけ持つ")
            }
        }
        if Set(review.map(\.platform)).count != review.count { violations.append("review のプラットフォームが重複している") }
        if let end, (end.reason == .abandoned) != (end.approval != nil) {
            violations.append("end の approval は、人がやめた（abandoned）ときだけ持つ")
        }
        if let integration {
            if Set(integration.map(\.base)).count != integration.count { violations.append("integration の取り込む先が重複している") }
            if integration.contains(where: { ($0.state == .open || $0.state == .merged) != (($0.pullRequest ?? 0) >= 1) }) {
                violations.append("integration の PR の番号は、open・merged のときだけ持つ")
            }
            if branch == nil { violations.append("integration は release ブランチを作った版だけ持つ") }
        }
        if let slots = appStoreVersions {
            if origin != .askhub { violations.append("版の枠は AskHub で始めた記録だけ持つ") }
            if Set(slots.map(\.platform)).count != slots.count { violations.append("appStoreVersions のプラットフォームが重複している") }
            if slots.contains(where: { !VersionSlot.isID($0.id) }) { violations.append("appStoreVersions の id の形が違う") }
            if slots.contains(where: { $0.build.map { !ReleaseFile.isBuildNumber($0) } ?? false }) {
                violations.append("appStoreVersions の build の形が違う")
            }
            if slots.contains(where: { ($0.removal == .kept) != ($0.removalNote != nil) }) {
                violations.append("appStoreVersions の removalNote は、消さなかった（kept）ときだけ持つ")
            }
        }
        if let rejections {
            if origin != .askhub { violations.append("rejections は AskHub で始めた記録だけ持つ") }
            violations += rejections.flatMap(\.problems)
        }
        if problem?.message.isEmpty == true { violations.append("problem の message が空") }
        return violations
    }
}
