import Foundation

public enum MacKind: String, Codable, Sendable, CaseIterable {
    /// 常時オンの Mac（司令塔とワーカー）
    case alwaysOn
    /// 常駐できる Mac（LaunchAgent。開いている間だけ動く）
    case resident
    /// 常駐できない Mac（ターミナルのコマンドで起動する）
    case manual
}

/// 生きている印を書くときの自己診断の結果
public struct SelfCheck: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable, CaseIterable {
        case ok
        case missing
        case invalid
        case expired
    }

    /// 持ち主（organization・個人）ごとの GitHub のトークンの様子。どの持ち主のトークンを入れ直すかを出すために書く。値そのものは書かない
    public struct GitHubToken: Codable, Equatable, Sendable {
        /// トークンを置いた持ち主（小文字にそろえた名前）
        public var owner: String
        public var state: State
        /// GitHub の API の応答の見出し（`github-authentication-token-expiration`）で分かった期限。期限の無いトークン・まだ分からないときは nil
        public var expiresAt: Timestamp?
        /// このトークンで読んだ REST の上限の残り。読めなかった（使えないトークン・GitHub の障害・前の版）ときは nil
        public var rateLimit: GitHubRateLimit?

        public init(owner: String, state: State, expiresAt: Timestamp? = nil, rateLimit: GitHubRateLimit? = nil) {
            self.owner = owner
            self.state = state
            self.expiresAt = expiresAt
            self.rateLimit = rateLimit
        }
    }

    public var checkedAt: Timestamp
    public var keychain: State
    /// 持ち主ごとのトークンをまとめた様子（1 つでも無ければ `missing`、次に `invalid`・`expired` の順）
    public var githubToken: State
    public var claudeToken: State
    /// 分かるときだけ書く。GitHub のトークンは持ち主ごとの期限のうち一番早いもの、setup-token は登録した日から 1 年
    public var githubTokenExpiresAt: Timestamp?
    public var claudeTokenExpiresAt: Timestamp?
    /// 持ち主ごとの内訳。書かない Mac（前の版）もある
    public var githubTokens: [GitHubToken]?

    public init(
        checkedAt: Timestamp,
        keychain: State,
        githubToken: State,
        claudeToken: State,
        githubTokenExpiresAt: Timestamp? = nil,
        claudeTokenExpiresAt: Timestamp? = nil,
        githubTokens: [GitHubToken]? = nil
    ) {
        self.checkedAt = checkedAt
        self.keychain = keychain
        self.githubToken = githubToken
        self.claudeToken = claudeToken
        self.githubTokenExpiresAt = githubTokenExpiresAt
        self.claudeTokenExpiresAt = claudeTokenExpiresAt
        self.githubTokens = githubTokens
    }

    /// 持ち主ごとのトークンで読んだ REST の上限の残りのうち、一番少ないもの。読めていなければ nil
    public var githubRateLimit: GitHubRateLimit? {
        githubTokens?.compactMap(\.rateLimit).min { $0.remaining < $1.remaining }
    }

    public var violations: [String] {
        guard let githubTokens else { return [] }
        var violations: [String] = []
        if githubTokens.contains(where: { !Self.isOwnerName($0.owner) }) { violations.append("githubTokens.owner の形が違う") }
        if Set(githubTokens.map(\.owner)).count != githubTokens.count { violations.append("githubTokens の持ち主が重なる") }
        if githubTokens.contains(where: { $0.rateLimit.map { $0.limit < 0 || $0.remaining < 0 } == true }) {
            violations.append("githubTokens.rateLimit の回数は 0 以上")
        }
        return violations
    }

    /// GitHub の持ち主の名前（英数字とハイフンで 1〜39 文字。ハイフンで始まらない）
    private static func isOwnerName(_ owner: String) -> Bool {
        let scalars = owner.unicodeScalars
        let isAllowed = { (scalar: Unicode.Scalar) in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
        }
        return (1...39).contains(scalars.count) && !owner.hasPrefix("-") && scalars.allSatisfy(isAllowed)
    }
}

/// GitHub の REST の一次の上限（`GET /rate_limit` の `resources.core`）。
///
/// 上限はトークンごとではなくアカウントごとに数える（同じアカウントの司令塔・アプリ・`gh` のトークンは、同じ回数を分け合う）
public struct GitHubRateLimit: Codable, Equatable, Sendable {
    /// 1 時間の上限（ふつうは 5,000）
    public var limit: Int
    /// 今の窓の残り
    public var remaining: Int
    /// 今の窓が終わり、`limit` に戻る時刻
    public var resetAt: Timestamp

    public init(limit: Int, remaining: Int, resetAt: Timestamp) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }

    /// 残りがこれを切ったら少ないとみなす（司令塔の通知・クライアントの警告と取り直しの間隔）。
    /// 2026-11-11 の使い切りの勢い（1 分に約 180 回）でも、使い切る 5 分ほど前に気づける
    public static let lowRemaining = 1_000

    /// 残りが少ないか。戻る時刻を過ぎていれば、もう戻っているので少なくない
    public func isLow(at now: Date) -> Bool {
        remaining < Self.lowRemaining && now < resetAt.date
    }
}

/// `macs/<mac>.json`（ワーカーの生きている印）。その Mac のワーカーだけが書く。変化があったときと、一定の間隔（10 分程度）でだけ書く
public struct MacFile: StateFile {
    public static let formatVersion = 1

    public struct Versions: Codable, Equatable, Sendable {
        public var worker: String
        public var claude: String?
        public var xcode: String?

        public init(worker: String, claude: String? = nil, xcode: String? = nil) {
            self.worker = worker
            self.claude = claude
            self.xcode = xcode
        }
    }

    /// Mac ごとの同時の上限
    public struct Capacity: Codable, Equatable, Sendable {
        public var claude: Int
        public var build: Int

        public init(claude: Int, build: Int) {
            self.claude = claude
            self.build = build
        }
    }

    public var mac: MacName
    public var kind: MacKind
    public var seenAt: Timestamp
    public var versions: Versions
    public var diskFreeGB: Int
    public var load: Double
    public var capacity: Capacity
    public var selfCheck: SelfCheck

    public init(
        mac: MacName,
        kind: MacKind,
        seenAt: Timestamp,
        versions: Versions,
        diskFreeGB: Int,
        load: Double,
        capacity: Capacity,
        selfCheck: SelfCheck
    ) {
        self.mac = mac
        self.kind = kind
        self.seenAt = seenAt
        self.versions = versions
        self.diskFreeGB = diskFreeGB
        self.load = load
        self.capacity = capacity
        self.selfCheck = selfCheck
    }

    public var violations: [String] {
        var violations: [String] = []
        if versions.worker.isEmpty { violations.append("versions.worker が空") }
        if diskFreeGB < 0 { violations.append("diskFreeGB は 0 以上") }
        if !(load >= 0) { violations.append("load は 0 以上") }
        if capacity.claude < 0 || capacity.build < 0 { violations.append("capacity は 0 以上") }
        return violations + selfCheck.violations
    }
}

/// `commander.json`（司令塔の生きている印）。司令塔だけが書く。GitHub Actions の見張りが `seenAt` の古さを確かめる
///
/// 常時オンの Mac では司令塔とワーカーが両方動くので、1 つのファイルの書き手を 1 つにするため、ワーカーの `macs/<mac>.json` と分ける
public struct CommanderFile: StateFile {
    public static let formatVersion = 1

    public struct Versions: Codable, Equatable, Sendable {
        public var commander: String
        public var claude: String?

        public init(commander: String, claude: String? = nil) {
            self.commander = commander
            self.claude = claude
        }
    }

    /// 司令塔が動いている Mac
    public var mac: MacName
    public var seenAt: Timestamp
    public var versions: Versions
    public var selfCheck: SelfCheck

    public init(mac: MacName, seenAt: Timestamp, versions: Versions, selfCheck: SelfCheck) {
        self.mac = mac
        self.seenAt = seenAt
        self.versions = versions
        self.selfCheck = selfCheck
    }

    public var violations: [String] {
        (versions.commander.isEmpty ? ["versions.commander が空"] : []) + selfCheck.violations
    }
}

public enum DevicePlatform: String, Codable, Sendable, CaseIterable {
    case ios
    case macos
}

/// 通知を送るサービス。Android を足すときに FCM を足す
public enum PushService: String, Codable, Sendable, CaseIterable {
    case apns
}

/// APNs の送り先の環境。Xcode から入れた版は development、TestFlight と App Store の版は production
public enum APNsEnvironment: String, Codable, Sendable, CaseIterable {
    case production
    case development
}

/// `devices/<device>.json`（通知の宛先）。その端末のクライアントだけが書く
public struct DeviceFile: StateFile {
    public static let formatVersion = 1

    /// 通知の送り先
    public struct Push: Codable, Equatable, Sendable {
        public var service: PushService
        /// APNs のデバイストークン（16 進）。送るときに URL のパスに入るので、16 進だけを受け付ける
        public var token: String
        /// APNs のときは必ず書く
        public var environment: APNsEnvironment?

        public init(service: PushService, token: String, environment: APNsEnvironment?) {
            self.service = service
            self.token = token
            self.environment = environment
        }
    }

    /// 端末の公開鍵の id
    public var device: KeyID
    public var platform: DevicePlatform
    public var push: Push
    public var updatedAt: Timestamp

    public init(device: KeyID, platform: DevicePlatform, push: Push, updatedAt: Timestamp) {
        self.device = device
        self.platform = platform
        self.push = push
        self.updatedAt = updatedAt
    }

    public var violations: [String] {
        var violations: [String] = []
        let isHex = push.token.utf8.allSatisfy {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains($0)
        }
        if !(16...400).contains(push.token.utf8.count) || !isHex { violations.append("push.token の形が違う") }
        if push.service == .apns && push.environment == nil { violations.append("APNs の宛先に environment が無い") }
        return violations
    }
}
