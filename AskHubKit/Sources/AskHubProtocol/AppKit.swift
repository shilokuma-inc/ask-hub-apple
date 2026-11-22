import Foundation

/// 共通リポジトリ app-kit の版（タグ `v<major>.<minor>.<patch>`。`docs/renewal/app-kit.md` の「版」）
public struct AppKitVersion: RawRepresentable, Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(rawValue: String) {
        guard rawValue.first == "v" else { return nil }
        let parts = rawValue.dropFirst().split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            // 先頭の 0 は 0 そのものだけ（`01` は受け付けない）。ブランチの名前にも使うので、1 つの数は 4 桁まで
            guard (1...4).contains(part.utf8.count), part.utf8.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
                  part.utf8.count == 1 || part.first != "0", let value = Int(part) else {
                return nil
            }
            numbers.append(value)
        }
        self.rawValue = rawValue
        (major, minor, patch) = (numbers[0], numbers[1], numbers[2])
    }

    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let version = Self(rawValue: text) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "app-kit の版の形でない: \(text)"))
        }
        self = version
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public var description: String { rawValue }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// app-kit の配り方の決まり（`docs/renewal/app-kit.md`）
public enum AppKitPolicy {
    /// 共通リポジトリ（public）
    public static let repository = RepositoryFullName(rawValue: "shilokuma-inc/app-kit")!
    /// 試しの 1 本の既定（司令塔の設定で替えられる）
    public static let defaultPilot = RepositoryFullName(rawValue: "tm-family/shinkeisuijaku-app-ios")!
    /// 各リポジトリの設定のパス
    public static let configPath = ".github/app-kit.json"
    /// 版を広げる PR のブランチ（`askhub/app-kit-v1.1.0`）
    public static func branch(for version: AppKitVersion) -> String {
        "askhub/app-kit-\(version.rawValue)"
    }

    /// 版を広げる相手のテンプレート（初めての入れ替えは人が手で行い、入れ替え済みのものにだけ広げる。2026-11-22 にユーザーが決めた）
    public static let templates = RepositoryTemplate.allCases.map(\.repository)
}

/// `app-kit.json`（共通リポジトリ app-kit の見つけた版と、版を広げる進み具合）。司令塔だけが書く。
///
/// 司令塔が、app-kit のタグを `git ls-remote --tags` で読んで版を書き、人の「広げる」（`rolloutAppKit`）を受けたら、
/// 試しの 1 本 → 残りの対象 → 入れ替え済みのテンプレートの順に、写すファイルを置き換える PR を出して進み具合を書く（`docs/renewal/app-kit.md` の「版を広げる」）
public struct AppKitFile: StateFile {
    public static let formatVersion = 1
    /// 残す版の数の上限（新しいものから残す）
    public static let maximumReleases = 30
    /// 変更点の長さの上限（Unicode のコードポイントの数。長ければ切る）
    public static let maximumChangesLength = 10_000

    /// app-kit の版 1 つ
    public struct Release: Codable, Equatable, Sendable {
        public var version: AppKitVersion
        /// タグが指すコミット（40 桁）
        public var ref: String
        /// そのタグの `CHANGELOG.md` の版の節（Markdown。見出しの行は除く）。読めなければ nil
        public var changes: String?
        /// 司令塔が見つけた時刻
        public var foundAt: Timestamp

        public init(version: AppKitVersion, ref: String, changes: String? = nil, foundAt: Timestamp) {
            self.version = version
            self.ref = ref
            self.changes = changes
            self.foundAt = foundAt
        }
    }

    /// 版とそのコミットの組
    public struct Pin: Codable, Equatable, Sendable {
        public var version: AppKitVersion
        public var ref: String

        public init(version: AppKitVersion, ref: String) {
            self.version = version
            self.ref = ref
        }
    }

    public typealias Rollout = AppKitRollout
    public typealias Target = AppKitRolloutTarget

    /// テンプレートに入っている版（テンプレートは `repos/` に無いので、ここに持つ）
    public struct Template: Codable, Equatable, Sendable {
        public var repo: RepositoryFullName
        /// 入っている版とずれ。まだ入れ替えていなければ nil（版を広げる相手にしない）
        public var appKit: RepositoryFile.AppKit?

        public init(repo: RepositoryFullName, appKit: RepositoryFile.AppKit? = nil) {
            self.repo = repo
            self.appKit = appKit
        }
    }

    /// 最後にタグを読んだ時刻（中身が変わったときだけ書き直す）。まだ読めていなければ nil
    public var checkedAt: Timestamp?
    /// 最後に読もうとして読めなかった理由。読めたら nil（読めなかったときは、前に読めた版を残す）
    public var problem: String?
    /// 見つけた版（新しい順）
    public var releases: [Release]
    /// 対象に加えるとき・準備をやり直すときに入れる版（最後に広げ終わった版。まだ広げていなければ、最初に見つけたときの一番新しい版）
    public var adoption: Pin?
    /// 広げている・最後に広げた版。まだ広げていなければ nil
    public var rollout: Rollout?
    /// テンプレートに入っている版
    public var templates: [Template]

    public init(
        checkedAt: Timestamp? = nil,
        problem: String? = nil,
        releases: [Release] = [],
        adoption: Pin? = nil,
        rollout: Rollout? = nil,
        templates: [Template] = []
    ) {
        self.checkedAt = checkedAt
        self.problem = problem
        self.releases = releases
        self.adoption = adoption
        self.rollout = rollout
        self.templates = templates
    }

    /// 一番新しい版
    public var latest: Release? { releases.first }

    /// 版の記録
    public func release(_ version: AppKitVersion) -> Release? {
        releases.first { $0.version == version }
    }

    public var violations: [String] {
        var violations: [String] = []
        if let problem, problem.isEmpty || problem.unicodeScalars.count > 1_000 { violations.append("problem は空でなく 1000 文字まで") }
        violations += releaseViolations
        if let adoption, !AttemptFile.isCommitSHA(adoption.ref) { violations.append("adoption.ref の形が違う") }
        violations += rollout?.violations ?? []
        let templateRepos = templates.map { $0.repo.rawValue.lowercased() }
        if Set(templateRepos).count != templateRepos.count { violations.append("templates のリポジトリが重なっている") }
        violations += templates.flatMap { template in template.appKit?.problems.map { "templates の \(template.repo) の \($0)" } ?? [] }
        return violations
    }

    private var releaseViolations: [String] {
        var violations: [String] = []
        if releases.count > Self.maximumReleases { violations.append("releases が \(Self.maximumReleases) を超える") }
        if releases.map(\.version) != releases.map(\.version).sorted(by: >) || Set(releases.map(\.version)).count != releases.count {
            violations.append("releases は版の新しい順で、重ならない")
        }
        if releases.contains(where: { !AttemptFile.isCommitSHA($0.ref) }) { violations.append("releases の ref の形が違う") }
        if releases.contains(where: { $0.changes.map { $0.isEmpty || $0.unicodeScalars.count > Self.maximumChangesLength } == true }) {
            violations.append("releases の changes は空でなく \(Self.maximumChangesLength) 文字まで")
        }
        return violations
    }
}

/// 版を広げる進み具合（`app-kit.json` の `rollout`）
public struct AppKitRollout: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        /// 広げている
        case running
        /// 失敗して止めた（理由は `problem`）。人が「もう一度試す」（同じ版の `rolloutAppKit`）か「やめる」（`stopAppKitRollout`）を選ぶ
        case failed
        /// 広げ終わった
        case finished
        /// 人がやめた（開いていた PR は閉じた）
        case stopped
    }

    public var version: AppKitVersion
    public var ref: String
    /// 広げる人の意図（もう一度試したときは、その意図）
    public var origin: IntentReference
    public var state: State
    /// 試しの 1 本
    public var pilot: RepositoryFullName
    /// PR を出した・出さなかった相手（出した順）
    public var targets: [AppKitRolloutTarget]
    /// 止めた理由（`failed` のとき）
    public var problem: String?
    public var startedAt: Timestamp
    public var updatedAt: Timestamp

    public init(
        version: AppKitVersion,
        ref: String,
        origin: IntentReference,
        state: State = .running,
        pilot: RepositoryFullName,
        targets: [AppKitRolloutTarget] = [],
        problem: String? = nil,
        startedAt: Timestamp,
        updatedAt: Timestamp
    ) {
        self.version = version
        self.ref = ref
        self.origin = origin
        self.state = state
        self.pilot = pilot
        self.targets = targets
        self.problem = problem
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    /// 相手の進み具合
    public func target(_ repo: RepositoryFullName) -> AppKitRolloutTarget? {
        targets.first { $0.repo == repo }
    }
}

/// 版を広げる相手 1 つの進み具合（`app-kit.json` の `rollout.targets`）
public struct AppKitRolloutTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        /// 対象のリポジトリ（`repos/`）
        case repository
        /// テンプレート
        case template
    }

    public enum State: String, Codable, Sendable, CaseIterable {
        /// PR を出して、必須のチェックを待っている
        case open
        /// マージして、develop の Build を待っている（試しの 1 本）
        case verifying
        /// 入れた（写すファイルがもう版の中身と同じで、PR が要らなかったときも）
        case done
        /// 止めた（PR は開いたまま。理由は `problem`）
        case failed
        /// 出さなかった（major が違う・準備の PR が開いている など。理由は `problem`）
        case skipped
        /// 人がやめたので、開いていた PR を閉じた
        case stopped
    }

    public var repo: RepositoryFullName
    public var kind: Kind
    public var state: State
    /// 出した PR の番号。PR が要らなかった・出さなかったなら nil
    public var pullRequest: Int?
    /// 出した PR の head。マージするときに、これと同じかを確かめる
    public var head: String?
    /// 止めた・出さなかった理由（人が読む文）
    public var problem: String?
    public var updatedAt: Timestamp

    public init(
        repo: RepositoryFullName,
        kind: Kind,
        state: State,
        pullRequest: Int? = nil,
        head: String? = nil,
        problem: String? = nil,
        updatedAt: Timestamp
    ) {
        self.repo = repo
        self.kind = kind
        self.state = state
        self.pullRequest = pullRequest
        self.head = head
        self.problem = problem
        self.updatedAt = updatedAt
    }
}

extension AppKitRollout {
    var violations: [String] {
        var violations: [String] = []
        if !AttemptFile.isCommitSHA(ref) { violations.append("rollout.ref の形が違う") }
        if let problem, problem.isEmpty || problem.unicodeScalars.count > 1_000 { violations.append("rollout.problem は空でなく 1000 文字まで") }
        if state == .failed, problem == nil { violations.append("rollout が failed なのに problem が無い") }
        let repos = targets.map { $0.repo.rawValue.lowercased() }
        if Set(repos).count != repos.count { violations.append("rollout.targets のリポジトリが重なっている") }
        for target in targets {
            if let pullRequest = target.pullRequest, pullRequest < 1 { violations.append("rollout.targets の pullRequest は 1 以上") }
            if let head = target.head, !AttemptFile.isCommitSHA(head) { violations.append("rollout.targets の head の形が違う") }
            if let problem = target.problem, problem.isEmpty || problem.unicodeScalars.count > 1_000 {
                violations.append("rollout.targets の problem は空でなく 1000 文字まで")
            }
            if [.failed, .skipped].contains(target.state), target.problem == nil {
                violations.append("rollout.targets の \(target.repo) が \(target.state.rawValue) なのに problem が無い")
            }
            if [.open, .verifying].contains(target.state), target.pullRequest == nil || target.head == nil {
                violations.append("rollout.targets の \(target.repo) の PR の番号と head が無い")
            }
        }
        return violations
    }
}

/// 人の意図が指す app-kit の版（`target` は `{ "type": "appKitRelease", "id": "<版>" }`、`targetVersion` は人が見たときの版のコミット）
public struct AppKitReleaseTarget: Equatable, Sendable {
    public static let targetType = "appKitRelease"

    public var version: AppKitVersion
    /// 人が見たときの版のコミット（40 桁）。司令塔は、タグが今もこのコミットを指すときだけ受け付ける
    public var ref: String

    public init(version: AppKitVersion, ref: String) {
        self.version = version
        self.ref = ref
    }

    init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.repo == nil else { throw .init(detail: "\(envelope.kind) に repo がある（app-kit の版の意図はリポジトリに結びつかない）") }
        guard let target = envelope.target, target.type == Self.targetType, target.epic == nil, let id = target.id,
              let version = AppKitVersion(rawValue: id) else {
            throw .init(detail: "target が appKitRelease の版でない")
        }
        guard let ref = envelope.targetVersion, AttemptFile.isCommitSHA(ref) else {
            throw .init(detail: "targetVersion が版のコミットでない")
        }
        _ = try PayloadReader(envelope.payload, allowed: [])
        self.init(version: version, ref: ref)
    }

    public var target: IntentEnvelope.Target {
        .init(type: Self.targetType, id: version.rawValue)
    }
}

/// app-kit の版を広げる人の意図（`rolloutAppKit`）。版ごとに 1 回。封筒の repo は書かず、target は版、targetVersion は版のコミット、payload は空。
/// 失敗して止めた版に同じ版でもう一度送ると、止めたところからやり直す。広げ終わった版に送ると、ずれたリポジトリに置き換える PR を出し直す
public struct RolloutAppKitIntent: Equatable, Sendable {
    public static let kind = "rolloutAppKit"

    public var release: AppKitReleaseTarget
    public var intent: IntentReference

    public init(release: AppKitReleaseTarget, intent: IntentReference) {
        self.release = release
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が rolloutAppKit でない") }
        let release = try AppKitReleaseTarget(envelope: envelope)
        self.init(release: release, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }
}

/// app-kit の版を広げるのをやめる人の意図（`stopAppKitRollout`）。封筒の形は `rolloutAppKit` と同じ。
/// 司令塔は、その版で開いている PR を閉じ、残りには出さない（マージ済みのものは戻さない。戻すときは前の版を広げる）
public struct StopAppKitRolloutIntent: Equatable, Sendable {
    public static let kind = "stopAppKitRollout"

    public var release: AppKitReleaseTarget
    public var intent: IntentReference

    public init(release: AppKitReleaseTarget, intent: IntentReference) {
        self.release = release
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が stopAppKitRollout でない") }
        let release = try AppKitReleaseTarget(envelope: envelope)
        self.init(release: release, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }
}
