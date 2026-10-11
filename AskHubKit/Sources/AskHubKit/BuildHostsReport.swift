import Foundation

/// オーケストレーターがビルドの Mac の状態用の Issue（ラベル `build-hosts`）の本文に書き出す、xcb のビルド先の Mac の状態。
///
/// ループのビルド・テストは xcb が複数の Mac に振り分ける。アプリは GitHub だけを見るので、xcb を動かしている Mac の
/// オーケストレーターが各 Mac の状態と実行中のループのビルドをここに書き、アプリが読む。本文の先頭に機械が読める目印（JSON）を置く:
///
/// ```html
/// <!-- ask-hub:build-hosts {"checkedAt":"2026-10-11T00:00:00Z","hosts":[...],"jobs":[...]} -->
/// ```
///
/// 詳細は `docs/protocol.md` の「ビルドの Mac の状態」を参照。
/// Mac の名前は xcb の `host`（ssh の Host 名）だけを持つ。ローカルパス・ssh の接続先アドレスは持たない
public struct BuildHostsReport: Sendable, Equatable, Codable {
    /// 状態用の Issue に付けるラベル
    public static let labelName = AskHubLabel.buildHosts.rawValue
    /// 状態用の Issue のタイトル
    public static let issueTitle = "【AskHub】ビルドの Mac の状態"
    /// 確認時刻を書き直す間隔（担当の印と同じ）。load・空きメモリもこのときだけ取り直す
    public static let updateInterval = OrchestratorHeartbeat.updateInterval
    /// 確認時刻がこの時間より古ければ、書き手がいないとみなす（担当の印と同じ）
    public static let freshness = OrchestratorHeartbeat.freshness

    /// ビルド先の Mac（xcb の `hosts`）
    public var hosts: [BuildHost]
    /// 実行中の、ループのスロットのビルド（それ以外のビルドは `BuildHost.running` の本数にだけ含める）
    public var jobs: [BuildHostJob]
    // 時刻は目印に秒までしか書かないので、読み戻した値と比べられるよう代入のたびに秒未満を切り捨てる

    /// load・空きメモリを xcb から取った時刻。取れていなければ `nil`
    public var measuredAt: Date? {
        didSet { measuredAt = measuredAt.map(Self.wholeSeconds) }
    }
    /// 書き手が最後に確かめた時刻。状態が変わらなくても `updateInterval` ごとに書き直す
    public var checkedAt: Date {
        didSet { checkedAt = Self.wholeSeconds(checkedAt) }
    }

    public init(hosts: [BuildHost], jobs: [BuildHostJob] = [], measuredAt: Date? = nil, checkedAt: Date) {
        self.hosts = hosts
        self.jobs = jobs
        self.measuredAt = measuredAt.map(Self.wholeSeconds)
        self.checkedAt = Self.wholeSeconds(checkedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case hosts, jobs, measuredAt, checkedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hosts: try container.decodeIfPresent([BuildHost].self, forKey: .hosts) ?? [],
            jobs: try container.decodeIfPresent([BuildHostJob].self, forKey: .jobs) ?? [],
            measuredAt: try container.decodeIfPresent(Date.self, forKey: .measuredAt),
            checkedAt: try container.decode(Date.self, forKey: .checkedAt)
        )
    }

    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    /// 確認時刻と、揺れる値（load・空きメモリ・コア数・それらを取った時刻）を除いて同じ状態か。
    /// 違うときだけ本文を書き換え、同じなら `updateInterval` ごとに確認時刻と揺れる値だけを書き直す
    public func hasSameStatus(as other: Self) -> Bool {
        stableStatus == other.stableStatus
    }

    private var stableStatus: Self {
        var stable = self
        stable.checkedAt = .distantPast
        stable.measuredAt = nil
        stable.hosts = hosts.map { host in
            var host = host
            host.cores = nil
            host.load = nil
            host.memoryFreePercent = nil
            return host
        }
        return stable
    }

    /// 書き手がいるか（確認時刻が `freshness` より新しいか）
    public func isAssigned(now: Date) -> Bool {
        OrchestratorHeartbeat.isAssigned(lastSeen: checkedAt, now: now)
    }

    // MARK: - 本文

    private static let commentOpen = "<!--"
    private static let commentClose = "-->"
    private static let keyword = "ask-hub:build-hosts"

    /// 状態用の Issue の本文。先頭に目印、続けて人が読める表を置く
    public var issueBody: String {
        let hostRows = hosts.map { "| " + $0.tableCells.map(Self.tableCell).joined(separator: " | ") + " |" }
        var body = """
        \(marker)
        ## ビルドの Mac の状態

        AskHub のオーケストレーターが書き換える Issue です。編集・クローズしないでください。

        | Mac | 状態 | load | コア数 | 空きメモリ | 実行中 / 枠 |
        | --- | --- | --- | --- | --- | --- |
        \(hostRows.joined(separator: "\n"))

        """
        if !jobs.isEmpty {
            let jobRows = jobs.map { job in
                let cells = [
                    job.host,
                    job.repository,
                    job.slot,
                    job.action + (job.platform.map { "（\($0)）" } ?? ""),
                    job.attempt.map { "\($0) 回目" } ?? "-",
                    job.startedAt.map { $0.formatted(.iso8601) } ?? "-"
                ]
                return "| " + cells.map(Self.tableCell).joined(separator: " | ") + " |"
            }
            body += """

            | Mac | リポジトリ | スロット | ビルド | 試行 | 開始 |
            | --- | --- | --- | --- | --- | --- |
            \(jobRows.joined(separator: "\n"))

            """
        }
        let measured = measuredAt.map { "（load・空きメモリ: \($0.formatted(.iso8601))）" } ?? ""
        body += "\n確認時刻: \(checkedAt.formatted(.iso8601))\(measured)\n"
        return body
    }

    /// 本文の先頭に置く目印
    var marker: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        // 自分の型の値だけなのでエンコードは失敗しない
        let encoded = (try? encoder.encode(self)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        // JSON の構文に `>` は無く、文字列の中にしか現れない。エスケープして目印の終わり（`-->`）と取り違えないようにする
        let json = encoded.replacingOccurrences(of: ">", with: "\\u003e")
        return "\(Self.commentOpen) \(Self.keyword) \(json) \(Self.commentClose)"
    }

    /// 状態用の Issue の本文から状態を読む。目印が先頭に無い・形式が崩れていれば `nil`。
    /// author が信用できるかはここでは判定しない（`TrustedAuthors` を使う）
    public static func parse(_ body: String) -> Self? {
        let trimmed = body.drop { $0.isWhitespace || $0.isNewline }
        guard trimmed.hasPrefix(commentOpen), let closeRange = trimmed.range(of: commentClose) else {
            return nil
        }
        let inner = trimmed[trimmed.index(trimmed.startIndex, offsetBy: commentOpen.count)..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inner.hasPrefix(keyword) else {
            return nil
        }
        let rest = inner.dropFirst(keyword.count)
        // `ask-hub:build-hosts-x` のような別の語を誤って拾わないよう、直後は空白に限る
        guard rest.first?.isWhitespace == true else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Self.self, from: Data(rest.utf8))
    }

    /// 表のセルに置けるよう、改行を空白にし `|` をエスケープする
    static func tableCell(_ text: String) -> String {
        text.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "|", with: "\\|")
    }
}

extension BuildHost {
    /// 状態用の Issue の表の 1 行（Mac・状態・load・コア数・空きメモリ・実行中 / 枠）
    var tableCells: [String] {
        var state = self.state.title
        if let reason {
            state += "（\(reason.title)）"
        }
        var runningText = "-"
        if let running {
            runningText = slots.map { "\(running) / \($0)" } ?? String(running)
        }
        return [
            name,
            state,
            load.map { String(format: "%.2f", $0) } ?? "-",
            cores.map(String.init) ?? "-",
            memoryFreePercent.map { "\($0)%" } ?? "-",
            runningText
        ]
    }
}
