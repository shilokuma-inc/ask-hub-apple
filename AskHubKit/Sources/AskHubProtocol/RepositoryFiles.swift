import Foundation

/// `version.json`（状態リポジトリ全体の形の版）。人が状態リポジトリを作るときだけ書く
public struct StateVersionFile: StateFile {
    public static let formatVersion = 1

    public init() {}
}

/// 対象のリポジトリのプラットフォーム
public enum RepositoryPlatform: String, Codable, Sendable, CaseIterable {
    case apple
}

/// 保護を掛けたときに外した・外せずに残った、重なる保護（`repo.json` の `protection.replaced`・`remaining`）
public struct ExistingProtection: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// クラシックのブランチ保護（`name` はパターン）
        case classic
        /// リポジトリのルールセット
        case ruleset
        /// organization のルールセット（リポジトリの側からは外せない）
        case organizationRuleset
    }

    public var kind: Kind
    public var name: String

    public init(kind: Kind, name: String) {
        self.kind = kind
        self.name = name
    }
}

/// 掛けたルールセットのずれ（`repo.json` の `protection.drift`。人が読む文）。ずれていなければ `drift` を nil にする
public struct ProtectionDrift: Codable, Equatable, Sendable {
    /// 今のずれを見つけた時刻（ずれの中身が変わったときだけ書き直す）
    public var foundAt: Timestamp
    public var problems: [String]

    public init(foundAt: Timestamp, problems: [String]) {
        self.foundAt = foundAt
        self.problems = problems
    }
}

/// `repos/<owner>/<repo>/repo.json`（対象のリポジトリの設定）。司令塔だけが書く
public struct RepositoryFile: StateFile {
    public static let formatVersion = 1

    public struct AppKit: Codable, Equatable, Sendable {
        /// 呼ぶ共通リポジトリの版（固定したコミットか、保護したタグ）
        public var ref: String

        public init(ref: String) {
            self.ref = ref
        }
    }

    /// ブランチの保護（ルールセット `askhub-protect`。`ProtectionPolicy`）。司令塔が、人の保護の設定（`applyProtection`）を処理して書き、
    /// 掛けた後のずれ（`drift`）を定期的に点検して書く
    public struct Protection: Codable, Equatable, Sendable {
        /// 人がクライアントで押して、保護を設定した時刻。まだなら nil
        public var appliedAt: Timestamp?
        /// 必須にしたチェックの名前（`applyProtection` の `requiredChecks`）
        public var requiredChecks: [String]?
        /// 掛けたルールセットの id
        public var rulesetId: Int?
        /// 掛けたときに外した、重なる保護
        public var replaced: [ExistingProtection]?
        /// 外せずに残った、重なる保護（organization のルールセット）
        public var remaining: [ExistingProtection]?
        /// 掛けた後のずれ。ずれていない・まだ確かめていなければ nil
        public var drift: ProtectionDrift?

        public init(
            appliedAt: Timestamp? = nil,
            requiredChecks: [String]? = nil,
            rulesetId: Int? = nil,
            replaced: [ExistingProtection]? = nil,
            remaining: [ExistingProtection]? = nil,
            drift: ProtectionDrift? = nil
        ) {
            self.appliedAt = appliedAt
            self.requiredChecks = requiredChecks
            self.rulesetId = rulesetId
            self.replaced = replaced
            self.remaining = remaining
            self.drift = drift
        }

        var problems: [String] {
            var problems: [String] = []
            if let requiredChecks { problems += ProtectionPolicy.problems(ofRequiredChecks: requiredChecks) }
            if let rulesetId, rulesetId < 1 { problems.append("protection.rulesetId は 1 以上") }
            let existing = (replaced ?? []) + (remaining ?? [])
            if existing.contains(where: { $0.name.isEmpty || $0.name.unicodeScalars.count > 300 }) {
                problems.append("protection の外した・残った保護の名前は空でなく、300 文字まで")
            }
            if let drift, drift.problems.isEmpty || drift.problems.contains(where: { $0.isEmpty || $0.unicodeScalars.count > 500 }) {
                problems.append("protection.drift.problems は 1 つ以上で、空でなく 500 文字まで")
            }
            return problems
        }
    }

    /// 対象のアプリのアイコン（画像は `StatePath.appIcon`）。司令塔が、対象のリポジトリの base（`build.baseBranch`。`build` が無ければ既定のブランチ）から取り出して書く
    public struct AppIcon: Codable, Equatable, Sendable {
        /// 取り出した元（Icon Composer の `.icon` か、Asset Catalog の `.appiconset` のフォルダ）の、リポジトリの直下からのパス
        public var source: String
        /// 元のフォルダの git の tree の sha。変わったときだけ書き出し直す
        public var sourceTree: String
        /// 書いた画像（PNG）の git の blob の sha。クライアントは、これを鍵に画像をしまっておく
        public var image: String
        public var updatedAt: Timestamp

        public init(source: String, sourceTree: String, image: String, updatedAt: Timestamp) {
            self.source = source
            self.sourceTree = sourceTree
            self.image = image
            self.updatedAt = updatedAt
        }

        var problems: [String] {
            var problems: [String] = []
            if source.isEmpty || source.utf8.count > 1_000 { problems.append("icon.source は空でなく、1000 バイトまで") }
            // git の tree と blob の sha は、コミットと同じ 40 桁の 16 進
            if !AttemptFile.isCommitSHA(sourceTree) { problems.append("icon.sourceTree の形が違う") }
            if !AttemptFile.isCommitSHA(image) { problems.append("icon.image の形が違う") }
            return problems
        }
    }

    public var repo: RepositoryFullName
    public var platform: RepositoryPlatform
    /// 同時に回す epic の上限（最初の版は 1）
    public var maxConcurrentEpics: Int
    /// 共通リポジトリのワークフローを入れる前は nil
    public var appKit: AppKit?
    public var protection: Protection
    /// ビルドの設定。人が入れる前は nil（開始を断る）
    public var build: Build?
    /// 対象のアプリのアイコン。まだ取り出していない・見つからないなら nil（クライアントは頭文字を出す）
    public var icon: AppIcon?
    /// 対象に加えるときの GitHub 側の準備の結果。まだ流していなければ nil
    public var setup: RepositorySetup?
    public var addedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        platform: RepositoryPlatform,
        maxConcurrentEpics: Int = 1,
        appKit: AppKit? = nil,
        protection: Protection = Protection(),
        build: Build? = nil,
        icon: AppIcon? = nil,
        addedAt: Timestamp
    ) {
        self.repo = repo
        self.platform = platform
        self.maxConcurrentEpics = maxConcurrentEpics
        self.appKit = appKit
        self.protection = protection
        self.build = build
        self.icon = icon
        self.addedAt = addedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        if maxConcurrentEpics < 1 { violations.append("maxConcurrentEpics は 1 以上") }
        if let appKit, appKit.ref.isEmpty { violations.append("appKit.ref が空") }
        violations += build?.problems ?? []
        violations += icon?.problems ?? []
        violations += protection.problems
        violations += setup?.violations ?? []
        return violations
    }
}

/// epic の段階（`docs/renewal/protocol.md` の表）
public enum EpicStage: String, Codable, Sendable, CaseIterable {
    /// 依頼を受け、質問を作っている
    case drafting
    /// 人の回答を待っている（説明待ち・ロックを含む）
    case asking
    /// 着手前の確認をしている
    case checking
    /// 着手前の確認で 1 つの epic に収まらないと分かり、分けて依頼し直すか、このまま 1 つで進めるかの、人の判断を待っている
    case awaitingSplit
    /// ゴールの確認と開始を待っている
    case awaitingStart
    /// 実装している
    case running
    /// 最終 PR の前の検証と、最終 PR の対処をしている
    case finalizing
    /// 人が決めていない判断の確認とマージを待っている
    case reviewing
    case merged
    /// やめた
    case abandoned
}

/// `repos/<owner>/<repo>/epics/<epic>/epic.json`（epic の状態）。司令塔だけが書く
public struct EpicFile: StateFile {
    public static let formatVersion = 1

    /// 最終 PR のマージの記録。どの端末から見ても、自動でマージしたか人が承認したかが分かるように、司令塔が `merged` にするときに書く
    public struct Merge: Codable, Equatable, Sendable {
        /// マージのコミット
        public var commit: String
        /// 人の承認（`approveMerge`）でマージしたなら、その意図。マージの規則で自動でマージしたなら nil
        public var approval: IntentReference?
        public var at: Timestamp

        public init(commit: String, approval: IntentReference? = nil, at: Timestamp) {
            self.commit = commit
            self.approval = approval
            self.at = at
        }
    }

    /// 人が一時停止した印（`pauseEpic`）。再開（`resumeEpic`）で外す。
    /// 付いている間、司令塔は epic の次のジョブを作らず、まだ動いていないジョブを `paused` にしたままにする（動いているジョブは最後まで終わらせる）
    public struct Pause: Codable, Equatable, Sendable {
        /// 一時停止を受け付けた時刻
        public var since: Timestamp
        /// 一時停止の人の意図
        public var origin: IntentReference

        public init(since: Timestamp, origin: IntentReference) {
            self.since = since
            self.origin = origin
        }
    }

    public var id: ULID
    public var repo: RepositoryFullName
    public var title: String
    /// 依頼の要約（質問づくりの Claude が書く。何を作るか・なぜ）。作る前は nil
    public var summary: String?
    /// 依頼の要約を置く Discussion の番号。作る前は nil
    public var discussion: Int?
    public var stage: EpicStage
    /// 開始のときに人が選んだ Mac。開始の前は nil
    public var mac: MacName?
    /// 作業ブランチ。作る前は nil
    public var branch: String?
    public var finalPullRequest: Int?
    /// 最終 PR のマージの記録。マージする前は nil
    public var merge: Merge?
    /// 人が一時停止した印。止めていなければ nil（Mac がオフラインでジョブが止まっているときは付かない）
    public var pause: Pause?
    /// 開始したときのゴールの版
    public var goalVersion: Int?
    /// 元になった依頼の人の意図
    public var origin: IntentReference?
    public var createdAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        id: ULID,
        repo: RepositoryFullName,
        title: String,
        summary: String? = nil,
        discussion: Int? = nil,
        stage: EpicStage,
        mac: MacName? = nil,
        branch: String? = nil,
        finalPullRequest: Int? = nil,
        merge: Merge? = nil,
        pause: Pause? = nil,
        goalVersion: Int? = nil,
        origin: IntentReference? = nil,
        createdAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.id = id
        self.repo = repo
        self.title = title
        self.summary = summary
        self.discussion = discussion
        self.stage = stage
        self.mac = mac
        self.branch = branch
        self.finalPullRequest = finalPullRequest
        self.merge = merge
        self.pause = pause
        self.goalVersion = goalVersion
        self.origin = origin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        if title.isEmpty { violations.append("title が空") }
        if let summary, summary.isEmpty { violations.append("summary が空") }
        if let discussion, discussion < 1 { violations.append("discussion は 1 以上") }
        if let finalPullRequest, finalPullRequest < 1 { violations.append("finalPullRequest は 1 以上") }
        if let merge, !AttemptFile.isCommitSHA(merge.commit) { violations.append("merge.commit の形が違う") }
        if let goalVersion, goalVersion < 1 { violations.append("goalVersion は 1 以上") }
        if let branch, !Self.isBranchName(branch) { violations.append("branch の形が違う") }
        return violations
    }

    /// git のコマンドに渡しても選択肢（`-` で始まる値）や別の書き方に読まれない、控えめな形だけを受け付ける
    public static func isBranchName(_ text: String) -> Bool {
        let isAllowed = { (byte: UInt8) in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "-")].contains(byte)
        }
        return (1...200).contains(text.utf8.count) && text.first != "-" && !text.contains("..")
            && text.utf8.allSatisfy(isAllowed)
    }
}
