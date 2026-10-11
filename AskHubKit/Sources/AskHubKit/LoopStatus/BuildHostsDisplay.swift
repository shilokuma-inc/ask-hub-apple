import Foundation

/// 「ビルドの Mac」の 1 台分に出す内容（UI に依存しない部分）
public struct BuildHostDisplay: Sendable, Equatable, Identifiable {
    /// 状態の色の分類。色そのものはアプリが決める
    public enum Tone: Sendable, Equatable {
        /// 使える
        case available
        /// 切断・使えない
        case unavailable
        /// 外している（`xcb drain`）・待機
        case idle
        /// 状態が分からない
        case unknown
    }

    /// xcb の Host 名
    public var name: String
    /// 「使える」「切断（接続できない）」
    public var statusText: String
    public var systemImage: String
    public var tone: Tone
    /// 「load 3.25 / 14 コア・空きメモリ 41%」。値が無ければ `nil`
    public var loadText: String?
    /// 「実行中 1 / 2」。本数が分からなければ `nil`
    public var runningText: String?
    /// この Mac で動いているループのビルド（「ask-hub-apple a: ビルド（iOS）・2 回目」）
    public var jobTexts: [String]

    public var id: String {
        name
    }
}

/// 直近 24 時間に別の Mac に移ったビルドの 1 件（全リポジトリをまとめた一覧の行）
public struct BuildMoveItem: Sendable, Equatable, Identifiable {
    /// リポジトリ（`owner/name`）
    public var repository: String
    /// 「a: ビルド macbookpro-m1pro → macbookpro-m4max（切断）」
    public var text: String
    /// 「成功」「失敗（終了コード 65）」
    public var resultText: String
    public var succeeded: Bool?
    public var finishedAt: Date?

    public var id: String {
        "\(repository) \(text) \(finishedAt?.timeIntervalSince1970 ?? 0)"
    }
}

extension BuildHostsStatus {
    /// 確認時刻が `BuildHostsReport.freshness` より古い（書き手の Mac のオーケストレーターがいない）
    public func isStale(now: Date) -> Bool {
        !report.isAssigned(now: now)
    }

    /// 各 Mac の行（`build-hosts` の Issue の並び）
    public var hostDisplays: [BuildHostDisplay] {
        report.hosts.map { host in
            let jobs = report.jobs.filter { $0.host == host.name }
            return BuildHostDisplay(
                name: host.name,
                statusText: host.state.title + (host.reason.map { "（\($0.title)）" } ?? ""),
                systemImage: Self.systemImage(of: host.state),
                tone: Self.tone(of: host.state),
                loadText: Self.loadText(of: host),
                runningText: host.running.map { running in host.slots.map { "実行中 \(running) / \($0)" } ?? "実行中 \(running)" },
                jobTexts: jobs.map(Self.jobText)
            )
        }
    }

    static func systemImage(of state: BuildHost.State) -> String {
        switch state {
        case .ok: "checkmark.circle.fill"
        case .down: "bolt.horizontal.circle"
        case .drained: "pause.circle"
        case .standby: "moon.circle"
        case .unknown: "questionmark.circle"
        }
    }

    static func tone(of state: BuildHost.State) -> BuildHostDisplay.Tone {
        switch state {
        case .ok: .available
        case .down: .unavailable
        case .drained, .standby: .idle
        case .unknown: .unknown
        }
    }

    static func loadText(of host: BuildHost) -> String? {
        var parts: [String] = []
        if let load = host.load {
            var text = "load " + load.formatted(.number.precision(.fractionLength(2)))
            if let cores = host.cores {
                text += " / \(cores) コア"
            }
            parts.append(text)
        }
        if let memory = host.memoryFreePercent {
            parts.append("空きメモリ \(memory)%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "・")
    }

    static func jobText(_ job: BuildHostJob) -> String {
        // 一覧は 1 台の Mac の中なので、owner を省いたリポジトリ名で足りる
        let name = job.repository.split(separator: "/").last.map(String.init) ?? job.repository
        var text = "\(name) \(job.slot): \(LoopStatusBuild.actionTitle(of: job.action))"
        if let platform = job.platform {
            text += "（\(platform)）"
        }
        if let attempt = job.attempt {
            text += "・\(attempt) 回目"
        }
        return text
    }
}

extension LoopStatusRow {
    /// 全リポジトリの、直近 24 時間に別の Mac に移ったビルド（新しい順）。担当 PC がいる行の目印だけを読む
    public static func buildMoves(in rows: [LoopStatusRow], now: Date, within interval: TimeInterval = 24 * 60 * 60) -> [BuildMoveItem] {
        rows.flatMap { row -> [BuildMoveItem] in
            guard case let .reported(report) = row.status(now: now), let moved = report.builds?.moved else {
                return []
            }
            return moved.compactMap { build in
                if let finishedAt = build.finishedAt, now.timeIntervalSince(finishedAt) > interval {
                    return nil
                }
                return BuildMoveItem(
                    repository: row.repository,
                    text: build.moveText,
                    resultText: build.resultText,
                    succeeded: build.succeeded,
                    finishedAt: build.finishedAt
                )
            }
        }
        .sorted { ($0.finishedAt ?? .distantPast) > ($1.finishedAt ?? .distantPast) }
    }
}

extension LoopStatusBuild {
    /// 「a: ビルド macbookpro-m1pro → macbookpro-m4max（切断）」。移動が続けば矢印でつなぐ
    var moveText: String {
        var hosts = moves.map(\.from)
        if let last = moves.last?.to ?? host {
            hosts.append(last)
        }
        // xcb が数えた移動の回数だけがあり、移動のイベントを読めていないこともある
        guard !moves.isEmpty else {
            return "\(slot): \(actionTitle) \(host ?? "Mac なし")（移動あり）"
        }
        var reasons: [String] = []
        for title in moves.map(\.reason.title) where !reasons.contains(title) {
            reasons.append(title)
        }
        return "\(slot): \(actionTitle) \(hosts.joined(separator: " → "))（\(reasons.joined(separator: "・"))）"
    }

    /// 「成功」「失敗（終了コード 65）」「実行中」
    var resultText: String {
        guard isFinished else {
            return "実行中"
        }
        return switch succeeded {
        case true?: "成功"
        case false?: exitCode.map { "失敗（終了コード \($0)）" } ?? "失敗"
        case nil: "終了"
        }
    }

    static func actionTitle(of action: String) -> String {
        switch action {
        case "build": "ビルド"
        case "test": "テスト"
        default: action
        }
    }
}
