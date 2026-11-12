import Foundation

/// App Store の版の番号（`MARKETING_VERSION`・App Store Connect の `versionString`）。`1.0.0` のように、0 以上の整数を `.` で 1〜3 個つないだもの。
/// 状態リポジトリのパス（`releases/<版>.json`）とタグの名前（`v<版>`）に使うので、読むときに形を確かめる
public struct MarketingVersion: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String
    /// 数の並び（`1.2.3` なら [1, 2, 3]）
    public let components: [Int]

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var components: [Int] = []
        for part in parts {
            // 先頭の 0 は 0 そのものだけ（`01` は受け付けない）。桁は App Store Connect の上限に合わせて 4 桁まで
            guard (1...4).contains(part.utf8.count), part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  part.utf8.count == 1 || part.first != "0", let value = Int(part) else {
                return nil
            }
            components.append(value)
        }
        self.rawValue = rawValue
        self.components = components
    }

    public var description: String { rawValue }

    /// 配信した版に付けるタグの名前（`v1.0.0`）
    public var tagName: String { "v\(rawValue)" }

    /// 次のマイナーの版（`1.2.3` → `1.3.0`、`1.2` → `1.3`、`1` → `1.1`）。数の数は 2 つ以上にそろえる
    public var nextMinor: MarketingVersion {
        var next = components.count >= 2 ? components : components + [0]
        next[1] += 1
        for index in next.indices.dropFirst(2) { next[index] = 0 }
        // 数を 1 つ上げただけなので、桁が上限（4 桁）を超えない限り、形は崩れない
        return MarketingVersion(rawValue: next.map(String.init).joined(separator: ".")) ?? self
    }

    /// 足りない数を 0 とみなして比べる（`1.2` と `1.2.0` は同じ）
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        let left = lhs.components + Array(repeating: 0, count: count - lhs.components.count)
        let right = rhs.components + Array(repeating: 0, count: count - rhs.components.count)
        return left.lexicographicallyPrecedes(right)
    }
}

/// App Store のプラットフォーム（App Store Connect の `platform`）
public enum AppStorePlatform: String, Codable, Sendable, CaseIterable {
    case iOS
    case macOS
    case visionOS
    case tvOS

    /// App Store Connect の API の値
    public var appStoreConnectValue: String {
        switch self {
        case .iOS: "IOS"
        case .macOS: "MAC_OS"
        case .visionOS: "VISION_OS"
        case .tvOS: "TV_OS"
        }
    }

    public init?(appStoreConnectValue: String) {
        guard let platform = Self.allCases.first(where: { $0.appStoreConnectValue == appStoreConnectValue }) else { return nil }
        self = platform
    }
}

/// `repos/<owner>/<repo>/releases/<版>.json`（App Store で配信した版と、その後作業の進み具合）。司令塔だけが書く。
///
/// 司令塔が App Store Connect で配信（Ready for Sale）を見つけたときに作り、後作業（コミットを求める → タグ → リリース文 →
/// GitHub Release、と、develop の版を次に上げる PR）を進めるたびに書き足す（`docs/renewal/release.md` の「配信の検知と後作業」）。
/// 人が確かめるのはリリース文だけで、公開の人の意図（`publishGitHubRelease`。`targetVersion` は `notes.version`）で GitHub Release を公開する
public struct ReleaseFile: StateFile {
    public static let formatVersion = 1

    /// 配信したプラットフォームの 1 つ
    public struct Platform: Codable, Equatable, Sendable {
        public var platform: AppStorePlatform
        /// 配信したビルドの番号（App Store Connect の build の `version`。`CFBundleVersion`）
        public var build: String
        /// そのビルドを App Store Connect に上げた時刻（コミットを求めるのに使う）。分からなければ nil
        public var uploadedAt: Timestamp?
        /// 司令塔が配信を見つけた時刻
        public var detectedAt: Timestamp

        public init(platform: AppStorePlatform, build: String, uploadedAt: Timestamp? = nil, detectedAt: Timestamp) {
            self.platform = platform
            self.build = build
            self.uploadedAt = uploadedAt
            self.detectedAt = detectedAt
        }
    }

    /// 配信したコミットをどう求めたか
    public enum CommitSource: String, Codable, Sendable, CaseIterable {
        /// ビルドを上げた Upload の実行（GitHub Actions）の head
        case uploadRun
        /// すでにあったタグ `v<版>`（人が手で付けたものなど）が指すコミット
        case existingTag
    }

    /// 配信したコミット
    public struct Commit: Codable, Equatable, Sendable {
        public var sha: String
        public var source: CommitSource
        /// 求めるのに使ったビルドのプラットフォームと番号（`existingTag` では nil）
        public var platform: AppStorePlatform?
        public var build: String?
        /// ビルドを上げた Upload の実行の id と番号（`uploadRun` のときだけ）
        public var run: Int?
        public var runNumber: Int?

        public init(
            sha: String,
            source: CommitSource,
            platform: AppStorePlatform? = nil,
            build: String? = nil,
            run: Int? = nil,
            runNumber: Int? = nil
        ) {
            self.sha = sha
            self.source = source
            self.platform = platform
            self.build = build
            self.run = run
            self.runNumber = runNumber
        }
    }

    /// 配信したコミットに付けたタグ（注釈付き）
    public struct Tag: Codable, Equatable, Sendable {
        /// `v<版>`
        public var name: String
        /// 司令塔が作ったなら true。前からあった（人が手で付けた）なら false
        public var created: Bool
        public var at: Timestamp

        public init(name: String, created: Bool, at: Timestamp) {
            self.name = name
            self.created = created
            self.at = at
        }
    }

    /// 人が確かめて公開を押したリリース文
    public struct ConfirmedNotes: Codable, Equatable, Sendable {
        /// 公開する本文（人が直したならその本文）
        public var text: String
        /// 公開の人の意図（`publishGitHubRelease`）
        public var approval: IntentReference
        public var at: Timestamp

        public init(text: String, approval: IntentReference, at: Timestamp) {
            self.text = text
            self.approval = approval
            self.at = at
        }
    }

    /// リリース文（Claude の下書きと、人が確かめたもの）
    public struct Notes: Codable, Equatable, Sendable {
        /// 下書きを作り直すたびに上げる。公開の人の意図の `targetVersion`
        public var version: Int
        /// 変更を数え始めたタグ（前に配信した版のタグ）。初めての配信なら nil
        public var previousTag: String?
        /// Claude の下書き（日本語の Markdown）
        public var draft: String
        public var draftedAt: Timestamp
        /// 人が確かめて公開を押したもの。押す前は nil
        public var confirmed: ConfirmedNotes?

        public init(version: Int, previousTag: String? = nil, draft: String, draftedAt: Timestamp, confirmed: ConfirmedNotes? = nil) {
            self.version = version
            self.previousTag = previousTag
            self.draft = draft
            self.draftedAt = draftedAt
            self.confirmed = confirmed
        }
    }

    /// 公開した GitHub Release
    public struct GitHubRelease: Codable, Equatable, Sendable {
        /// Release の画面の URL（`https://github.com/<owner>/<repo>/releases/tag/v<版>`）
        public var url: String
        /// 司令塔が公開したなら true。前からあった（人が手で作った）なら false
        public var created: Bool
        public var at: Timestamp

        public init(url: String, created: Bool, at: Timestamp) {
            self.url = url
            self.created = created
            self.at = at
        }
    }

    public enum NextVersionState: String, Codable, Sendable, CaseIterable {
        /// 版を上げる PR を開いている（CI を待っている）
        case open
        /// PR をマージした
        case merged
        /// develop の版がもう配信した版より大きいので、上げなかった
        case skipped
    }

    /// develop の `MARKETING_VERSION` を次の版に上げる PR
    public struct NextVersion: Codable, Equatable, Sendable {
        /// 上げた先の版（既定は次のマイナー）。`skipped` なら、develop にもうあった版
        public var version: MarketingVersion
        public var state: NextVersionState
        /// 版を上げる PR の番号（`skipped` なら nil）
        public var pullRequest: Int?
        public var at: Timestamp

        public init(version: MarketingVersion, state: NextVersionState, pullRequest: Int? = nil, at: Timestamp) {
            self.version = version
            self.state = state
            self.pullRequest = pullRequest
            self.at = at
        }
    }

    /// 後作業の段取り
    public enum Step: String, Codable, Sendable, CaseIterable {
        case commit
        case tag
        case notes
        case githubRelease
        case nextVersion
    }

    /// 後作業を進められなかった理由（進められたら消す）。司令塔は次に確かめるときにやり直す
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
    /// 配信したプラットフォーム（見つけた順）。1 つ以上
    public var platforms: [Platform]
    public var commit: Commit?
    public var tag: Tag?
    public var notes: Notes?
    public var githubRelease: GitHubRelease?
    public var nextVersion: NextVersion?
    public var problem: Problem?
    public var detectedAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        version: MarketingVersion,
        platforms: [Platform],
        commit: Commit? = nil,
        tag: Tag? = nil,
        notes: Notes? = nil,
        githubRelease: GitHubRelease? = nil,
        nextVersion: NextVersion? = nil,
        problem: Problem? = nil,
        detectedAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.repo = repo
        self.version = version
        self.platforms = platforms
        self.commit = commit
        self.tag = tag
        self.notes = notes
        self.githubRelease = githubRelease
        self.nextVersion = nextVersion
        self.problem = problem
        self.detectedAt = detectedAt
        self.updatedAt = updatedAt
    }

    /// 人がリリース文を確かめて公開を押すのを待っている（「あなたの番」に出す）
    public var awaitsNotesReview: Bool {
        githubRelease == nil && notes != nil && notes?.confirmed == nil
    }

    /// 後作業がすべて終わった（タグ・GitHub Release・次の版）
    public var isFinished: Bool {
        tag != nil && githubRelease != nil && (nextVersion?.state == .merged || nextVersion?.state == .skipped)
    }

    public var violations: [String] {
        var violations: [String] = []
        if platforms.isEmpty { violations.append("platforms が空") }
        if Set(platforms.map(\.platform)).count != platforms.count { violations.append("platforms のプラットフォームが重複している") }
        if platforms.contains(where: { !Self.isBuildNumber($0.build) }) { violations.append("platforms の build の形が違う") }
        if let commit {
            if !Self.isCommit(commit.sha) { violations.append("commit の sha が 40 桁の 16 進でない") }
            switch commit.source {
            case .uploadRun:
                if commit.platform == nil || commit.build == nil || commit.run == nil || commit.runNumber == nil {
                    violations.append("Upload の実行から求めたコミットには、platform・build・run・runNumber が要る")
                }
            case .existingTag:
                if commit.run != nil || commit.runNumber != nil { violations.append("タグから求めたコミットは run・runNumber を持たない") }
            }
            if let build = commit.build, !Self.isBuildNumber(build) { violations.append("commit の build の形が違う") }
            if [commit.run, commit.runNumber].contains(where: { ($0 ?? 1) < 1 }) { violations.append("run・runNumber は 1 以上") }
        }
        if let tag, tag.name != version.tagName { violations.append("tag の name が v<版> でない") }
        if tag != nil && commit == nil { violations.append("tag はコミットを求めてから作る") }
        if let notes {
            if notes.version < 1 { violations.append("notes の version は 1 以上") }
            if notes.draft.isEmpty { violations.append("notes の draft が空") }
            if notes.confirmed?.text.isEmpty == true { violations.append("notes の confirmed の text が空") }
            if notes.previousTag.map({ MarketingVersion(rawValue: String($0.dropFirst())) == nil || !$0.hasPrefix("v") }) == true {
                violations.append("notes の previousTag が v<版> の形でない")
            }
        }
        if githubRelease != nil && tag == nil { violations.append("GitHub Release はタグを作ってから公開する") }
        if let nextVersion {
            switch nextVersion.state {
            case .open, .merged:
                if nextVersion.pullRequest.map({ $0 < 1 }) ?? true { violations.append("版を上げる PR の番号が無い") }
                if nextVersion.version <= version { violations.append("次の版が配信した版より大きくない") }
            case .skipped:
                if nextVersion.pullRequest != nil { violations.append("上げなかったときは PR を持たない") }
            }
        }
        if problem?.message.isEmpty == true { violations.append("problem の message が空") }
        return violations
    }

    /// ビルドの番号（`CFBundleVersion`）。0 以上の整数を `.` で 1〜3 個つないだもの（App Store Connect の決まり）
    static func isBuildNumber(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        return (1...3).contains(parts.count) && parts.allSatisfy { part in
            (1...18).contains(part.utf8.count) && part.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
        }
    }

    static func isCommit(_ text: String) -> Bool {
        text.utf8.count == 40 && text.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }
}
