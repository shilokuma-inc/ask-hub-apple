import AskHubProtocol
import CryptoKit
import Foundation

/// 1 回に送る通知。1 つの epic か Mac ごとに、その周に見つけた出来事をまとめる（質問がまとめて出ても 1 通にする）
public struct PushNotice: Equatable, Sendable {
    public var title: String
    public var subtitle: String?
    public var body: String
    /// 通知センターでまとめる単位（epic の id・Mac の名前）
    public var thread: String
    /// 同じ通知を端末で 1 つにまとめる id。まとめた出来事の key から決める（APNs の上限の 64 バイトに収まる）
    public var collapseID: String
    /// クライアントが開く先（`repo`・`epic`・`mac`）
    public var target: [String: String]
    /// まとめた出来事の key
    public var keys: [String]

    public init(title: String, subtitle: String? = nil, body: String, thread: String, target: [String: String], keys: [String]) {
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.thread = thread
        self.target = target
        self.keys = keys
        let digest = SHA256.hash(data: Data(keys.sorted().joined(separator: "\n").utf8))
        collapseID = digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 出来事を、epic か Mac ごとの通知にまとめる。並びは見つけた順。時刻は `timeZone`（司令塔の Mac の時間帯）で書く
    static func compose(_ blockers: [Blocker], epics: [EpicFile], now: Date, timeZone: TimeZone = .current) -> [PushNotice] {
        var scopes: [Blocker.Scope] = []
        var groups: [Blocker.Scope: [Blocker]] = [:]
        for blocker in blockers {
            if groups[blocker.scope] == nil { scopes.append(blocker.scope) }
            groups[blocker.scope, default: []].append(blocker)
        }
        let titles = Dictionary(epics.map { ($0.id, $0.title) }) { first, _ in first }
        return scopes.map { scope in
            let blockers = groups[scope] ?? []
            switch scope {
            case let .epic(repo, epic):
                return PushNotice(
                    title: shortened(titles[epic] ?? repo.name),
                    subtitle: repo.rawValue,
                    body: epicLines(blockers.map(\.reason)).joined(separator: "\n"),
                    thread: epic.rawValue,
                    target: ["repo": repo.rawValue, "epic": epic.rawValue],
                    keys: blockers.map(\.key)
                )
            case let .mac(mac):
                return PushNotice(
                    title: "\(mac) がオフライン",
                    body: blockers.map { macLine($0.reason, now: now) }.joined(separator: "\n"),
                    thread: "mac/\(mac)",
                    target: ["mac": mac.rawValue],
                    keys: blockers.map(\.key)
                )
            case let .rateLimit(mac):
                return PushNotice(
                    title: "GitHub の残りが少なくなりました",
                    body: blockers.compactMap { rateLimitLines($0.reason, timeZone: timeZone) }.joined(separator: "\n"),
                    thread: "github/rate-limit",
                    target: ["mac": mac.rawValue],
                    keys: blockers.map(\.key)
                )
            case let .release(repo, version):
                return PushNotice(
                    title: "\(repo.name) \(version) を配信しました",
                    subtitle: repo.rawValue,
                    body: blockers.compactMap { releaseLine($0.reason) }.joined(separator: "\n"),
                    thread: "release/\(repo.rawValue)/\(version.rawValue)",
                    target: ["repo": repo.rawValue, "release": version.rawValue],
                    keys: blockers.map(\.key)
                )
            }
        }
    }

    /// 例: 残り 820 回（1 時間 5,000 回）。15:54 に戻ります。（改行）askhub status のループなど、GitHub を多く使うものを止めてください
    private static func rateLimitLines(_ reason: Blocker.Reason, timeZone: TimeZone) -> String? {
        guard case let .rateLimit(limit) = reason else { return nil }
        let locale = Locale(identifier: "ja_JP")
        let count = { (value: Int) in value.formatted(.number.locale(locale)) }
        let reset = limit.resetAt.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
        return "残り \(count(limit.remaining)) 回（1 時間 \(count(limit.limit)) 回）。\(reset) に戻ります。\n"
            + "askhub status のループなど、GitHub を多く使うものを止めてください"
    }

    /// epic の出来事の文。人がすることの順（開始・分け方・回答・最終 PR の確認・失敗の判断）に並べる
    private static func epicLines(_ reasons: [Blocker.Reason]) -> [String] {
        var lines: [String] = []
        for case let .start(revised) in reasons {
            lines.append(revised ? "ゴールを直しました。確かめて開始してください" : "ゴールができました。確かめて開始してください")
        }
        if reasons.contains(.split) { lines.append("1 つの epic に収まりません。分け方を選んでください") }
        let questions = reasons.filter { if case .question = $0 { true } else { false } }.count
        if questions > 0 { lines.append("質問 \(questions) 件が回答を待っています") }
        for case let .review(pullRequest, decisions, revised) in reasons {
            let done = revised ? "最終 PR #\(pullRequest) の直しが済みました" : "最終 PR #\(pullRequest) のレビューが通りました"
            let ask = decisions > 0 ? "判断のカード \(decisions) 件に答えて、マージを承認してください" : "確かめてマージを承認してください"
            lines.append("\(done)。\(ask)")
        }
        var kinds: [JobKind] = []
        var counts: [JobKind: Int] = [:]
        for case let .job(kind) in reasons {
            if counts[kind] == nil { kinds.append(kind) }
            counts[kind, default: 0] += 1
        }
        for kind in kinds {
            let count = counts[kind] ?? 0
            lines.append("\(kind.label)\(count > 1 ? "（\(count) 件）" : "")が止まり、判断を待っています")
        }
        return lines
    }

    private static func releaseLine(_ reason: Blocker.Reason) -> String? {
        switch reason {
        case .releaseNotes: "リリース文を確かめて、GitHub Release を公開してください"
        case let .releaseProblem(step): "後作業（\(step.label)）が止まっています。確かめてください"
        default: nil
        }
    }

    private static func macLine(_ reason: Blocker.Reason, now: Date) -> String {
        guard case let .macOffline(jobs, seenAt) = reason else { return "" }
        let hours = max(Int(now.timeIntervalSince(seenAt.date) / 3_600), 1)
        return "ジョブ \(jobs) 件を持ったまま、\(hours) 時間以上戻っていません"
    }

    /// 長い題は、通知の 1 行に収まるよう縮める
    private static func shortened(_ text: String, limit: Int = 60) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

extension JobKind {
    /// 通知の文に出す名前
    var label: String {
        switch self {
        case .makeQuestions: "質問づくり"
        case .explain: "説明づくり"
        case .reviseQuestion: "質問の見直し"
        case .checkReadiness: "着手前の確認"
        case .reviseGoal: "ゴールの修正"
        case .prepareWorkspace: "作業場所の用意"
        case .implementTask: "タスクの実装"
        case .reviewTask: "子 PR のレビュー"
        case .fixTask: "タスクの直し"
        case .integrateDevelop: "develop の取り込み"
        case .verifyBeforeFinal: "最終 PR の前の検証"
        case .reviewFinalPullRequest: "最終 PR のレビュー"
        case .openFinalPullRequest: "最終 PR の作成"
        case .fixFinalPullRequest: "最終 PR の直し"
        case .rerunChecks: "CI の流し直し"
        case .classifyDecisions: "判断の仕分け"
        case .captureScreenshots: "スクショの撮影"
        case .mergeFinalPullRequest: "最終 PR のマージ"
        case .cleanUp: "片付け"
        case .notify: "通知"
        }
    }
}

extension ReleaseFile.Step {
    /// 通知とログに出す名前
    var label: String {
        switch self {
        case .commit: "配信したコミットを求める"
        case .tag: "タグ"
        case .notes: "リリース文"
        case .githubRelease: "GitHub Release"
        case .nextVersion: "次の版の PR"
        }
    }
}
