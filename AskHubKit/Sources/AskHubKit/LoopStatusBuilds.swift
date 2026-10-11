import Foundation

/// リポジトリのループのスロットで動いた xcb のビルド・テスト（目印の `builds`）。
///
/// オーケストレーターが xcb のイベントから組み立てる。Mac の名前は xcb の `host`（ssh の Host 名）をそのまま書く。
/// ローカルパスは書かず、スロット（`a` / `b`）だけを持つ。キーはすべて任意で、無ければ空として読む
public struct LoopStatusBuilds: Sendable, Equatable, Codable {
    /// 実行中のビルド
    public var running: [LoopStatusBuild]
    /// 直近に終わったビルド（スロットごとに 1 件。移動の有無を問わない）
    public var latest: [LoopStatusBuild]
    /// 直近 24 時間に終わった、移動のあったビルド（新しい順）
    public var moved: [LoopStatusBuild]

    public init(running: [LoopStatusBuild] = [], latest: [LoopStatusBuild] = [], moved: [LoopStatusBuild] = []) {
        self.running = running
        self.latest = latest
        self.moved = moved
    }

    private enum CodingKeys: String, CodingKey {
        case running, latest, moved
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            running: try container.decodeIfPresent([LoopStatusBuild].self, forKey: .running) ?? [],
            latest: try container.decodeIfPresent([LoopStatusBuild].self, forKey: .latest) ?? [],
            moved: try container.decodeIfPresent([LoopStatusBuild].self, forKey: .moved) ?? []
        )
    }

    /// 書くものが無いか
    public var isEmpty: Bool {
        running.isEmpty && latest.isEmpty && moved.isEmpty
    }
}

/// xcb の 1 つのジョブ（ビルド・テスト）
public struct LoopStatusBuild: Sendable, Equatable, Codable {
    /// ループのスロット（`a` / `b`）
    public var slot: String
    /// xcb の `action`（`build` / `test` など）
    public var action: String
    /// xcb の `platform`（`iOS` / `macOS` など）
    public var platform: String?
    /// 今（終わったものは最後に）動いた Mac の Host 名。`local` は xcb を動かしている Mac。どこでも動かなかったら `nil`
    public var host: String?
    /// 何回目の試行か（終わったものは試行の回数）
    public var attempt: Int?
    /// 別の Mac への移動（古い順）
    public var moves: [LoopStatusBuildMove]
    /// 終わったときの終了コード。実行中は `nil`
    public var exitCode: Int?
    /// かかった秒数（終わったもの）
    public var seconds: Int?
    // 時刻は目印に秒までしか書かないので、読み戻した値と比べられるよう秒未満を切り捨てる

    /// 始まった時刻
    public var startedAt: Date? {
        didSet { startedAt = startedAt.map(LoopStatusReport.wholeSeconds) }
    }
    /// 終わった時刻。実行中は `nil`
    public var finishedAt: Date? {
        didSet { finishedAt = finishedAt.map(LoopStatusReport.wholeSeconds) }
    }

    public init(
        slot: String,
        action: String,
        platform: String? = nil,
        host: String? = nil,
        attempt: Int? = nil,
        moves: [LoopStatusBuildMove] = [],
        exitCode: Int? = nil,
        seconds: Int? = nil,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) {
        self.slot = slot
        self.action = action
        self.platform = platform
        self.host = host
        self.attempt = attempt
        self.moves = moves
        self.exitCode = exitCode
        self.seconds = seconds
        self.startedAt = startedAt.map(LoopStatusReport.wholeSeconds)
        self.finishedAt = finishedAt.map(LoopStatusReport.wholeSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case slot, action, platform, host, attempt, moves, exitCode, seconds, startedAt, finishedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            slot: try container.decode(String.self, forKey: .slot),
            action: try container.decode(String.self, forKey: .action),
            platform: try container.decodeIfPresent(String.self, forKey: .platform),
            host: try container.decodeIfPresent(String.self, forKey: .host),
            attempt: try container.decodeIfPresent(Int.self, forKey: .attempt),
            moves: try container.decodeIfPresent([LoopStatusBuildMove].self, forKey: .moves) ?? [],
            exitCode: try container.decodeIfPresent(Int.self, forKey: .exitCode),
            seconds: try container.decodeIfPresent(Int.self, forKey: .seconds),
            startedAt: try container.decodeIfPresent(Date.self, forKey: .startedAt),
            finishedAt: try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        )
    }

    /// 終わったか
    public var isFinished: Bool {
        exitCode != nil
    }

    /// 成功したか。実行中は `nil`
    public var succeeded: Bool? {
        exitCode.map { $0 == 0 }
    }
}

/// 別の Mac への移動（xcb の `job_moved`）
public struct LoopStatusBuildMove: Sendable, Equatable, Codable {
    /// 移動元の Host 名
    public var from: String
    /// 移動先の Host 名（次の試行の `host`）。まだ移動先が決まっていなければ `nil`
    public var to: String?
    public var reason: Reason
    /// 移動した時刻
    public var movedAt: Date? {
        didSet { movedAt = movedAt.map(LoopStatusReport.wholeSeconds) }
    }

    public init(from: String, to: String? = nil, reason: Reason, movedAt: Date? = nil) {
        self.from = from
        self.to = to
        self.reason = reason
        self.movedAt = movedAt.map(LoopStatusReport.wholeSeconds)
    }

    private enum CodingKeys: String, CodingKey {
        case from, to, reason, movedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            from: try container.decode(String.self, forKey: .from),
            to: try container.decodeIfPresent(String.self, forKey: .to),
            reason: try container.decodeIfPresent(Reason.self, forKey: .reason) ?? .unknown,
            movedAt: try container.decodeIfPresent(Date.self, forKey: .movedAt)
        )
    }

    /// 移動の理由（xcb の `reason`）
    public enum Reason: String, Sendable, CaseIterable, Codable {
        /// 移動元の Mac が切断された（持ち出しなど）
        case disconnected
        /// 移動元の Mac にその platform のビルド環境が無かった
        case noPlatform = "no_platform"
        /// このアプリが知らない理由。書き出しには使わない
        case unknown

        public init(from decoder: any Decoder) throws {
            let rawValue = try decoder.singleValueContainer().decode(String.self)
            self = Self(rawValue: rawValue) ?? .unknown
        }

        /// 人が読む表に出す名前
        public var title: String {
            switch self {
            case .disconnected: "切断"
            case .noPlatform: "ビルド環境なし"
            case .unknown: "不明"
            }
        }
    }
}

// MARK: - 本文の表

extension LoopStatusBuilds {
    /// 状態用の Issue の表に足す行
    var tableRows: [(String, String)] {
        var rows: [(String, String)] = []
        if !running.isEmpty {
            rows.append(("ビルド中", running.map(\.tableText).joined(separator: "<br>")))
        }
        if !latest.isEmpty {
            rows.append(("直近のビルド", latest.map(\.tableText).joined(separator: "<br>")))
        }
        if !moved.isEmpty {
            rows.append(("24 時間の移動", moved.map(\.tableText).joined(separator: "<br>")))
        }
        return rows
    }
}

extension LoopStatusBuild {
    /// 「a: build（iOS）macbookpro-m4max・2 回目（macbookpro-m1pro から移動: 切断）・成功」
    var tableText: String {
        var text = "\(slot): \(action)"
        if let platform {
            text += "（\(platform)）"
        }
        text += " \(host ?? "Mac なし")"
        if let attempt {
            text += "・\(attempt) 回目"
        }
        if !moves.isEmpty {
            let moveText = moves.map { "\($0.from) から移動: \($0.reason.title)" }.joined(separator: "、")
            text += "（\(moveText)）"
        }
        if let succeeded {
            text += succeeded ? "・成功" : "・失敗"
        }
        if let date = finishedAt ?? startedAt {
            text += "・\(date.formatted(.iso8601))"
        }
        return LoopStatusReport.tableCell(text)
    }
}
