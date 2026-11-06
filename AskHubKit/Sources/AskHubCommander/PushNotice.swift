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

    /// 出来事を、epic か Mac ごとの通知にまとめる。並びは見つけた順
    static func compose(_ blockers: [Blocker], epics: [EpicFile], now: Date) -> [PushNotice] {
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
            }
        }
    }

    /// epic の出来事の文。人がすることの順（開始・分け方・回答・失敗の判断）に並べる
    private static func epicLines(_ reasons: [Blocker.Reason]) -> [String] {
        var lines: [String] = []
        for case let .start(revised) in reasons {
            lines.append(revised ? "ゴールを直しました。確かめて開始してください" : "ゴールができました。確かめて開始してください")
        }
        if reasons.contains(.split) { lines.append("1 つの epic に収まりません。分け方を選んでください") }
        let questions = reasons.filter { if case .question = $0 { true } else { false } }.count
        if questions > 0 { lines.append("質問 \(questions) 件が回答を待っています") }
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
        case .fixTask: "タスクの直し"
        case .integrateDevelop: "develop の取り込み"
        case .verifyBeforeFinal: "最終 PR の前の検証"
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
