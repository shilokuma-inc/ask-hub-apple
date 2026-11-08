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

    public struct Protection: Codable, Equatable, Sendable {
        /// 人がクライアントで押して、保護を設定した時刻。まだなら nil
        public var appliedAt: Timestamp?

        public init(appliedAt: Timestamp? = nil) {
            self.appliedAt = appliedAt
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
    public var addedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        platform: RepositoryPlatform,
        maxConcurrentEpics: Int = 1,
        appKit: AppKit? = nil,
        protection: Protection = Protection(),
        build: Build? = nil,
        addedAt: Timestamp
    ) {
        self.repo = repo
        self.platform = platform
        self.maxConcurrentEpics = maxConcurrentEpics
        self.appKit = appKit
        self.protection = protection
        self.build = build
        self.addedAt = addedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        if maxConcurrentEpics < 1 { violations.append("maxConcurrentEpics は 1 以上") }
        if let appKit, appKit.ref.isEmpty { violations.append("appKit.ref が空") }
        violations += build?.problems ?? []
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
