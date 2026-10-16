import Foundation

/// xcb のビルド先の 1 台の Mac（ビルドの Mac の状態用の Issue の `hosts`）
public struct BuildHost: Sendable, Equatable, Codable {
    /// xcb の `host`（ssh の Host 名。例 `macbookpro-m4max`）。`local` は xcb を動かしている Mac
    public var name: String
    public var state: State
    /// 使えない理由（`down` のとき）。xcb の理由の文はローカルパスを含むことがあるので、分類だけを書く
    public var reason: Reason?
    /// CPU のコア数（`xcb status --json` から。取れていなければ `nil`）
    public var cores: Int?
    /// load average（`xcb status --json` から）
    public var load: Double?
    /// 空きメモリの割合（0〜100。`xcb status --json` から）
    public var memoryFreePercent: Int?
    /// この Mac で実行中の xcb のビルドの本数。ループのスロット以外のビルドも含める
    public var running: Int?
    /// この Mac で同時に実行できる本数
    public var slots: Int?

    public init(
        name: String,
        state: State,
        reason: Reason? = nil,
        cores: Int? = nil,
        load: Double? = nil,
        memoryFreePercent: Int? = nil,
        running: Int? = nil,
        slots: Int? = nil
    ) {
        self.name = name
        self.state = state
        self.reason = reason
        self.cores = cores
        self.load = load
        self.memoryFreePercent = memoryFreePercent
        self.running = running
        self.slots = slots
    }

    /// Mac の状態（xcb の `state`）
    public enum State: String, Sendable, CaseIterable, Codable {
        /// 使える
        case ok
        /// 切断されている・使えない
        case down
        /// 候補から外している（`xcb drain`）
        case drained
        /// 待機（xcb を動かしている Mac 自身。空いているとき、またはリモートがつながらないときだけ使う。xcb の `local`）
        case standby
        /// このアプリが知らない状態。書き出しには使わない
        case unknown

        public init(from decoder: any Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }

        /// 人が読む表に出す名前
        public var title: String {
            switch self {
            case .ok: "使える"
            case .down: "切断"
            case .drained: "外している"
            case .standby: "待機"
            case .unknown: "不明"
            }
        }
    }

    /// 使えない理由の分類
    public enum Reason: String, Sendable, CaseIterable, Codable {
        /// 接続できない（持ち出し・スリープ・ネットワークの切断）
        case unreachable
        /// ビルドの実行中に切断された
        case disconnected
        /// Xcode の準備ができていない
        case xcodeNotReady = "xcode-not-ready"
        /// このアプリが知らない理由。書き出しには使わない
        case unknown

        public init(from decoder: any Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }

        /// 人が読む表に出す名前
        public var title: String {
            switch self {
            case .unreachable: "接続できない"
            case .disconnected: "実行中に切断"
            case .xcodeNotReady: "Xcode が未準備"
            case .unknown: "不明"
            }
        }
    }
}

/// ビルドの Mac で実行中の、ループのスロットのビルド（ビルドの Mac の状態用の Issue の `jobs`）
public struct BuildHostJob: Sendable, Equatable, Codable {
    /// 動いている Mac の Host 名（`BuildHost.name`）
    public var host: String
    /// リポジトリ（`owner/name`）
    public var repository: String
    /// ループのスロット（`a` / `b`）。ローカルパスは書かない
    public var slot: String
    /// xcb の `action`（`build` / `test` など）
    public var action: String
    /// xcb の `platform`（`iOS` / `macOS` など）
    public var platform: String?
    /// 何回目の試行か
    public var attempt: Int?
    /// 始まった時刻（秒未満は切り捨てる）
    public var startedAt: Date? {
        didSet { startedAt = startedAt.map(BuildHostsReport.wholeSeconds) }
    }

    public init(
        host: String,
        repository: String,
        slot: String,
        action: String,
        platform: String? = nil,
        attempt: Int? = nil,
        startedAt: Date? = nil
    ) {
        self.host = host
        self.repository = repository
        self.slot = slot
        self.action = action
        self.platform = platform
        self.attempt = attempt
        self.startedAt = startedAt.map(BuildHostsReport.wholeSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case host, repository, slot, action, platform, attempt, startedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            host: try container.decode(String.self, forKey: .host),
            repository: try container.decode(String.self, forKey: .repository),
            slot: try container.decode(String.self, forKey: .slot),
            action: try container.decode(String.self, forKey: .action),
            platform: try container.decodeIfPresent(String.self, forKey: .platform),
            attempt: try container.decodeIfPresent(Int.self, forKey: .attempt),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt)
        )
    }
}
