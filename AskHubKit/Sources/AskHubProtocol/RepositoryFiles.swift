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
    public var addedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        platform: RepositoryPlatform,
        maxConcurrentEpics: Int = 1,
        appKit: AppKit? = nil,
        protection: Protection = Protection(),
        addedAt: Timestamp
    ) {
        self.repo = repo
        self.platform = platform
        self.maxConcurrentEpics = maxConcurrentEpics
        self.appKit = appKit
        self.protection = protection
        self.addedAt = addedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        if maxConcurrentEpics < 1 { violations.append("maxConcurrentEpics は 1 以上") }
        if let appKit, appKit.ref.isEmpty { violations.append("appKit.ref が空") }
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

    public var id: ULID
    public var repo: RepositoryFullName
    public var title: String
    /// 依頼の要約を置く Discussion の番号。作る前は nil
    public var discussion: Int?
    public var stage: EpicStage
    /// 開始のときに人が選んだ Mac。開始の前は nil
    public var mac: MacName?
    /// 作業ブランチ。作る前は nil
    public var branch: String?
    public var finalPullRequest: Int?
    /// 開始したときのゴールの版
    public var goalVersion: Int?
    public var createdAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        id: ULID,
        repo: RepositoryFullName,
        title: String,
        discussion: Int? = nil,
        stage: EpicStage,
        mac: MacName? = nil,
        branch: String? = nil,
        finalPullRequest: Int? = nil,
        goalVersion: Int? = nil,
        createdAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.id = id
        self.repo = repo
        self.title = title
        self.discussion = discussion
        self.stage = stage
        self.mac = mac
        self.branch = branch
        self.finalPullRequest = finalPullRequest
        self.goalVersion = goalVersion
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        if title.isEmpty { violations.append("title が空") }
        if let discussion, discussion < 1 { violations.append("discussion は 1 以上") }
        if let finalPullRequest, finalPullRequest < 1 { violations.append("finalPullRequest は 1 以上") }
        if let goalVersion, goalVersion < 1 { violations.append("goalVersion は 1 以上") }
        if let branch, !Self.isBranchName(branch) { violations.append("branch の形が違う") }
        return violations
    }

    /// git のコマンドに渡しても選択肢（`-` で始まる値）や別の書き方に読まれない、控えめな形だけを受け付ける
    static func isBranchName(_ text: String) -> Bool {
        let isAllowed = { (byte: UInt8) in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || [UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "/"), UInt8(ascii: "-")].contains(byte)
        }
        return (1...200).contains(text.utf8.count) && text.first != "-" && !text.contains("..")
            && text.utf8.allSatisfy(isAllowed)
    }
}
