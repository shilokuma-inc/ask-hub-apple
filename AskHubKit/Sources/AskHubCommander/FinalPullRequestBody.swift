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

    /// 撮る画面を選べなかった（一覧に合う画面が無い）仮決めのカードに出す文
    static let noScene = "この仮決めが出る画面は、撮れる画面の一覧に無い"
    /// 撮る画面を選んだが、まだ撮っていない仮決めのカードに出す文
    static let capturing = "撮影中（撮れたら、この本文に載せる）"
    /// 撮ったが GitHub に上げていない仮決めのカードに出す文
    static let onlyInClient = "Before / After のスクショは、AskHub のクライアントで見られる"

    /// `capturesScreenshots` は、リポジトリに撮影の設定（`build.screenshots`）があるか
    static func text(
        epic: EpicFile,
        goal: GoalFile,
        decisions: DecisionsFile?,
        branches: FinalBranches,
        capturesScreenshots: Bool = false
    ) -> String {
        let items = decisions?.items ?? []
        let screens = capturesScreenshots ? decisions?.screens ?? [] : []
        let visible = items.filter { $0.visible != false }
        let details = items.filter { $0.visible == false }
        var sections = [
            "AskHub が epic「\(safe(epic.title))」の最終 PR として出しました。作業ブランチ `\(branches.epic)` を `\(branches.base)` に merge commit でマージします。",
            "## 何を作ったか\n\n\(safe(goal.summary))",
            "## タスク\n\n" + list(goal.tasks.map { "\($0.id): \(safe($0.title))" }),
            "## 人が決めていない判断（見える仮決め）\n\n" + cards(visible, capturesScreenshots: capturesScreenshots, screens: screens)
        ]
        // 画面の変化（仮決めに結びつかない、epic 全体で見た目が変わった画面）。選んだ画面があるときだけ出す
        if !screens.isEmpty {
            sections.append("## 画面の変化\n\n" + screens.map(screenChange).joined(separator: "\n\n"))
        }
        if !details.isEmpty {
            let lines = details.map { "- \($0.id): \(safe($0.what))（\(safe($0.why))）" }.joined(separator: "\n")
            sections.append("<details><summary>内部の細部の仮決め（\(details.count) 件）</summary>\n\n\(lines)\n\n</details>")
        }
        sections.append("## 実機で確かめてほしいこと\n\n\(verificationGuide)\n\n" + list(verificationItems(goal)))
        let done = goal.humanTasks.filter { $0.state == .done }
        if !done.isEmpty {
            sections.append("## 人がした作業\n\n" + list(done.map { "\($0.id): \(safe($0.title))" }))
        }
        let body = String(sections.joined(separator: "\n\n").prefix(maximumLength))
        let marker = JSONValue.object(["type": .string("finalPullRequest"), "epic": .string(epic.id.rawValue)])
        return ProtocolMarker.text(body: body, marker: marker)
    }

    /// 見える仮決めのカード（1 件ずつ見出しを付ける）
    private static func cards(_ items: [DecisionsFile.Item], capturesScreenshots: Bool, screens: [DecisionsFile.ScreenChange]) -> String {
        guard !items.isEmpty else { return "見える仮決めはありません。" }
        let cards = items.map { item in
            let alternatives = item.alternatives.isEmpty ? "なし" : item.alternatives.map(safe).joined(separator: "・")
            return """
            ### \(item.id): \(safe(item.what))

            - なぜ: \(safe(item.why))
            - ほかの案: \(alternatives)
            - 画面の変化: \(screenshots(of: item, capturesScreenshots: capturesScreenshots, screens: screens))
            """
        }
        return "AskHub のクライアントで 1 件ずつ「OK」「別案にする」「直してほしい」を選んでください。全部を確かめ終えるまでマージしません。\n\n"
            + cards.joined(separator: "\n\n")
    }

    /// カードの「画面の変化」。GitHub に上げた画像があれば、Before / After の表にする（`DecisionsFile.Screenshots` が確かめた URL だけを載せる）
    /// 「画面の変化」に同じ画面があれば、表を繰り返さずに、そこを見るよう書く（Before / After は同じ画像なので）
    static func screenshots(of item: DecisionsFile.Item, capturesScreenshots: Bool, screens: [DecisionsFile.ScreenChange] = []) -> String {
        guard capturesScreenshots else { return noScreenshots }
        if let scene = item.scene, screens.contains(where: { $0.scene == scene }) { return "下の「画面の変化」の `\(scene)` を見る" }
        guard let shots = item.screenshots else { return item.scene == nil ? noScene : capturing }
        let scene = item.scene.map { "`\($0)` の画面" } ?? "画面"
        return images(shots, label: item.id, heading: scene, indent: "  ")
    }

    /// 「画面の変化」の 1 画面（見出しと Before / After の表）
    static func screenChange(_ screen: DecisionsFile.ScreenChange) -> String {
        let title = screen.title.map { "\(safe($0))（`\(screen.scene)`）" } ?? "`\(screen.scene)`"
        guard let shots = screen.screenshots else { return "### \(title)\n\n\(capturing)" }
        return "### \(title)\n\n" + images(shots, label: screen.scene, heading: "", indent: "")
    }

    /// Before / After の表。上げた画像が無ければ、AskHub で見られることと、撮れなかったわけを書く
    private static func images(_ shots: DecisionsFile.Screenshots, label: String, heading: String, indent: String) -> String {
        let note = shots.note.map { "（\(safe($0))）" } ?? ""
        guard shots.beforeURL != nil || shots.afterURL != nil else { return onlyInClient + note }
        let cell = { (url: String?, side: String) in
            guard let url, DecisionsFile.Screenshots.isAttachmentURL(url) else { return "なし" }
            return #"<img src="\#(url)" alt="\#(label) \#(side)" width="300">"#
        }
        let table = """
            \(indent)| Before | After |
            \(indent)| --- | --- |
            \(indent)| \(cell(shots.beforeURL, "Before")) | \(cell(shots.afterURL, "After")) |
            """
        // 見出しもわけも無ければ（画面の変化の節）、表だけにする（見出しの下に空行を重ねない）
        let lead = heading + note
        return lead.isEmpty ? table : "\(lead)\n\n\(table)"
    }

    /// 「実機で確かめてほしいこと」の頼み方（クライアントの実機確認のカードと同じ操作を書く）
    static let verificationGuide = """
        マージは止めません。マージした後に AskHub の「あなたの番」に「実機で確かめる」が出るので、TestFlight に上がった版で確かめて、\
        項目ごとに「確認した」か「問題あり」を付けてください。「問題あり」は新しい依頼になります。
        """

    /// 実機確認の項目。ゴールの完了の条件を、クライアントと同じ id（`v1` から）で並べる
    static func verificationItems(_ goal: GoalFile) -> [String] {
        goal.doneWhen.enumerated().map { "\(VerificationTarget.itemID(at: $0.offset)): \(safe($0.element))" }
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
