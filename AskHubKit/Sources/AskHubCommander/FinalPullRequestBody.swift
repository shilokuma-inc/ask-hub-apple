import AskHubCommands
import AskHubProtocol
import Foundation

/// 最終 PR の本文（`docs/renewal/flows.md` の「人が決めていない判断の確認」「実機で確かめてほしいこと」）。
///
/// 見える仮決めは 1 件ずつカードにし、内部の細部は畳んで並べる。仕分ける前の仮決め（`visible` が nil）は見えるものとして出す
/// （マージの規則と同じ）。本文の最後の行に、機械が書いた最終 PR の目印を置く
enum FinalPullRequestBody {
    /// 撮影の設定（`build.screenshots`）が無いリポジトリで、判断のカードに出す文
    static let noScreenshots = "スクショ無し（このリポジトリには撮影の設定が無い）"
    /// GitHub の PR の本文の上限（65,536 文字）に、目印の分を残して収める
    static let maximumLength = 60_000

    static func text(epic: EpicFile, goal: GoalFile, decisions: DecisionsFile?, branches: FinalBranches) -> String {
        let items = decisions?.items ?? []
        let visible = items.filter { $0.visible != false }
        let details = items.filter { $0.visible == false }
        var sections = [
            "AskHub が epic「\(safe(epic.title))」の最終 PR として出しました。作業ブランチ `\(branches.epic)` を `\(branches.base)` に merge commit でマージします。",
            "## 何を作ったか\n\n\(safe(goal.summary))",
            "## タスク\n\n" + list(goal.tasks.map { "\($0.id): \(safe($0.title))" }),
            "## 人が決めていない判断（見える仮決め）\n\n" + cards(visible)
        ]
        if !details.isEmpty {
            let lines = details.map { "- \($0.id): \(safe($0.what))（\(safe($0.why))）" }.joined(separator: "\n")
            sections.append("<details><summary>内部の細部の仮決め（\(details.count) 件）</summary>\n\n\(lines)\n\n</details>")
        }
        sections.append(
            "## 実機で確かめてほしいこと\n\nマージは止めません。TestFlight に上がった後に、AskHub のクライアントで「確認した」「問題あり」を付けてください。\n\n"
                + list(goal.doneWhen.map(safe))
        )
        let done = goal.humanTasks.filter { $0.state == .done }
        if !done.isEmpty {
            sections.append("## 人がした作業\n\n" + list(done.map { "\($0.id): \(safe($0.title))" }))
        }
        let body = String(sections.joined(separator: "\n\n").prefix(maximumLength))
        let marker = JSONValue.object(["type": .string("finalPullRequest"), "epic": .string(epic.id.rawValue)])
        return ProtocolMarker.text(body: body, marker: marker)
    }

    /// 見える仮決めのカード（1 件ずつ見出しを付ける）
    private static func cards(_ items: [DecisionsFile.Item]) -> String {
        guard !items.isEmpty else { return "見える仮決めはありません。" }
        let cards = items.map { item in
            let alternatives = item.alternatives.isEmpty ? "なし" : item.alternatives.map(safe).joined(separator: "・")
            let screenshots = item.screenshots == nil ? noScreenshots : "Before / After のスクショは、AskHub のクライアントで見られる"
            return """
            ### \(item.id): \(safe(item.what))

            - なぜ: \(safe(item.why))
            - ほかの案: \(alternatives)
            - 画面の変化: \(screenshots)
            """
        }
        return "AskHub のクライアントで 1 件ずつ「OK」「別案にする」「直してほしい」を選んでください。全部を確かめ終えるまでマージしません。\n\n"
            + cards.joined(separator: "\n\n")
    }

    private static func list(_ lines: [String]) -> String {
        lines.isEmpty ? "なし" : lines.map { "- \($0)" }.joined(separator: "\n")
    }

    /// 人の依頼と Claude の報告から来た文を、本文に入れられる形にする。
    /// トークンらしい文字列を伏せ、メンション（`@coderabbitai` など。コードの中でも効く）と HTML のコメントの始まりを効かなくし、改行を空白にする
    static func safe(_ text: String) -> String {
        Redaction.redact(text, secrets: [])
            .replacing(#/@(?=[A-Za-z0-9])/#, with: "@\u{200B}")
            .replacing("<!--", with: "&lt;!--")
            .replacing(#/\s*\n\s*/#, with: " ")
    }
}
