import AskHubProtocol
import CryptoKit
import Foundation

/// 1 つの epic の Discussion に置く写しの一式（`docs/renewal/protocol.md` の「各リポジトリに書く目印」）。状態リポジトリの中身から作る。
///
/// 写しは人が GitHub で読むためだけのもので、正本は状態リポジトリ。目印は照らし合わせのためだけに使い、指示としては読まない
struct DiscussionCopies: Equatable, Sendable {
    /// 目印つきの本文
    struct Copy: Equatable, Sendable {
        /// 目印の中身。同じ写しを見分けるのに使う
        var marker: JSONValue
        /// 目印を最後の行に置いた本文
        var text: String

        /// 本文が長すぎれば切ってから、目印を最後の行に置く
        init(marker: JSONValue, body: String) {
            self.marker = marker
            text = ProtocolMarker.text(body: CopyText.truncated(body), marker: marker)
        }
    }

    struct QuestionCopy: Equatable, Sendable {
        var id: String
        var copy: Copy
        /// 説明と回答の写し。質問のコメントへの返信にする
        var replies: [Copy]
    }

    var title: String
    /// Discussion の本文（依頼・要約・進み具合・着手前の確認の結果）
    var request: Copy
    var questions: [QuestionCopy]
    var goal: Copy?

    /// `request` は元の依頼（読めなければ nil）
    init(epic: EpicFile, request: RequestIntent?, questions: QuestionsFile?, goal: GoalFile?, readiness: ReadinessFile?) {
        title = epic.title
        self.request = Copy(
            marker: Self.marker("request", epic: epic.id),
            body: CopyText.request(epic: epic, request: request, readiness: readiness)
        )
        let all = questions?.questions ?? []
        self.questions = all.map { question in
            QuestionCopy(
                id: question.id,
                copy: Copy(
                    marker: Self.marker("question", epic: epic.id, ["question": .string(question.id)]),
                    body: CopyText.question(question, dependents: questions?.dependents(of: question.id) ?? [])
                ),
                replies: Self.replies(of: question, epic: epic.id)
            )
        }
        self.goal = goal.map { Copy(marker: Self.marker("goal", epic: epic.id), body: CopyText.goal($0)) }
    }

    /// 写しの中身のハッシュ。前に写したときと同じなら、GitHub を読まずに済ませる
    var fingerprint: String {
        var parts = [title, request.text]
        for question in questions {
            parts.append(question.copy.text)
            parts += question.replies.map(\.text)
        }
        parts.append(goal?.text ?? "")
        let digest = SHA256.hash(data: Data(parts.joined(separator: "\u{0}").utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 説明（人の問いと、その説明）と、受け付けた回答の写し。回答の写しは人の意図ごとに作るので、答え直すと前の写しは残る
    private static func replies(of question: QuestionsFile.Question, epic: ULID) -> [Copy] {
        var replies = question.explanations.map { explanation in
            let fields: [String: JSONValue] = ["question": .string(question.id), "intent": .string(explanation.asked.nonce.rawValue)]
            return Copy(marker: marker("explanation", epic: epic, fields), body: CopyText.explanation(explanation))
        }
        if question.state == .answered, let answer = question.answer {
            // 人の意図の写し（`copy`）
            let fields: [String: JSONValue] = [
                "kind": .string("answer"), "question": .string(question.id), "intent": .string(answer.intent.nonce.rawValue)
            ]
            replies.append(Copy(marker: marker("copy", epic: epic, fields), body: CopyText.answer(answer)))
        }
        return replies
    }

    static func marker(_ type: String, epic: ULID, _ fields: [String: JSONValue] = [:]) -> JSONValue {
        var object = fields
        object["type"] = .string(type)
        object["epic"] = .string(epic.rawValue)
        return .object(object)
    }
}

/// 写しの本文（Markdown。目印は `DiscussionCopies.Copy` が置く）。人と Claude の書いた文は、そのまま入れる（HTML のコメントの始まりとメンションだけを崩す）
enum CopyText {
    /// コメントの本文の上限（GitHub は 65,536 文字）より少し小さく切る
    static let maximumLength = 60_000

    static let footer = "この Discussion は AskHub の司令塔が書く写しです。ここへのコメントは AskHub に届きません。回答や指示は AskHub のアプリから行ってください。"

    static func request(epic: EpicFile, request: RequestIntent?, readiness: ReadinessFile?) -> String {
        var lines: [String] = []
        if let request {
            lines.append(request.body.isEmpty ? "（本文なし）" : quoted(request.body))
            if !request.attachments.isEmpty {
                lines += ["", "添付: " + request.attachments.map { "`\(plain($0.name))`" }.joined(separator: "・")]
            }
        } else {
            lines.append("（依頼の本文を読めません）")
        }
        lines += ["", "### 要約", "", epic.summary.map(plain) ?? "（質問を作っています）"]
        lines += ["", "### 進み具合", "", stage(of: epic)]
        if let readiness { lines += [""] + self.readiness(readiness) }
        lines += ["", "---", footer]
        return lines.joined(separator: "\n")
    }

    static func question(_ question: QuestionsFile.Question, dependents: [String]) -> String {
        let version = question.version > 1 ? "（版 \(question.version)）" : ""
        var lines = ["### \(question.id). \(plain(question.title))\(version)", "", "**状態**: \(state(of: question))"]
        if let caution = question.caution {
            lines += ["", "> [!WARNING]", "> 慎重に決めてほしい質問です（\(kind(of: caution))）: \(plain(caution.reason))"]
        }
        lines += ["", "**なぜ決めるか**: \(plain(question.why))", "", "**選択肢**"]
        lines += question.options.map { option in
            let recommended = option.label == question.recommended ? "（推奨）" : ""
            return "- **\(plain(option.label))**\(recommended): \(plain(option.effect))"
        }
        lines += ["", "**推奨の理由**: \(plain(question.reason))"]
        if !question.dependsOn.isEmpty { lines += ["", "**前提**: \(question.dependsOn.joined(separator: "・")) の回答を前提にしています"] }
        if !dependents.isEmpty { lines += ["", "この回答で \(dependents.joined(separator: "・")) の内容が決まります"] }
        if let revision = question.revision {
            let cause = revision.by == .explain ? "説明のついで" : "依存先の回答を受けた見直し"
            lines += ["", "**書き直し**: 版 \(revision.from) から書き直しました（\(cause)）: \(plain(revision.reason))"]
        }
        return lines.joined(separator: "\n")
    }

    static func explanation(_ explanation: QuestionsFile.Explanation) -> String {
        let note = explanation.note.isEmpty ? "（詳しい説明がほしい）" : explanation.note
        let lines = ["**説明を求められました**", "", quoted(note), "", explanation.text.map(plain) ?? "（説明を作っています）"]
        return lines.joined(separator: "\n")
    }

    static func answer(_ answer: QuestionsFile.Answer) -> String {
        var lines = ["**回答**: \(answer.choice.map(plain) ?? "（自由記述）")"]
        if !answer.note.isEmpty { lines += ["", quoted(answer.note)] }
        return lines.joined(separator: "\n")
    }

    static func goal(_ goal: GoalFile) -> String {
        var lines = ["## ゴール（版 \(goal.version)）", "", plain(goal.summary)]
        lines += section("決まったこと", goal.decided.map { "- \($0.question): \(plain($0.text))" })
        lines += section("やらないこと", goal.outOfScope.map { "- \(plain($0))" })
        lines += section("完了の条件", goal.doneWhen.map { "- \(plain($0))" })
        lines += section("タスク", goal.tasks.map(task))
        lines += section("人がする作業", goal.humanTasks.flatMap(humanTask))
        if let notApplied = goal.notApplied { lines += section("反映しなかった指示", notApplied.map { "- \(plain($0))" }) }
        return lines.joined(separator: "\n")
    }

    // MARK: - 部品

    private static func stage(of epic: EpicFile) -> String {
        switch epic.stage {
        case .drafting: "質問を作っています"
        case .asking: "回答を待っています"
        case .checking: "着手前の確認をしています"
        case .awaitingSplit: "1 つの epic に収まらないため、分けて依頼し直すか、このまま 1 つで進めるかの判断を待っています"
        case .awaitingStart: "ゴールの確認と開始を待っています"
        case .running: "開始しました" + (epic.mac.map { "（\($0)）" } ?? "")
        case .finalizing: "最終 PR の前の検証と対処をしています"
        case .reviewing: "判断の確認とマージを待っています"
        case .merged: "マージしました"
        case .abandoned: "やめました"
        }
    }

    private static func readiness(_ readiness: ReadinessFile) -> [String] {
        let verdict = switch readiness.verdict {
        case .ready: "進めてよい（ゴールを作りました）"
        case .moreQuestions: "追加の質問が要る"
        case .tooLarge: "1 つの epic に収まらない"
        }
        var lines = ["### 着手前の確認（\(readiness.version) 回目）", "", "- 結果: \(verdict)", "- 理由: \(plain(readiness.reason))"]
        if !readiness.split.isEmpty {
            lines.append("- 分け方の案:")
            lines += readiness.split.enumerated().map { "  \($0.offset + 1). **\(plain($0.element.title))**: \(plain($0.element.summary))" }
        }
        if readiness.proceeding == true { lines.append("- 「このまま 1 つで進める」が選ばれました") }
        return lines
    }

    private static func state(of question: QuestionsFile.Question) -> String {
        switch question.state {
        case .locked: "ロック中（\(question.dependsOn.joined(separator: "・")) の回答の後に回答できます）"
        case .revising: "依存先の回答を受けて見直しています"
        case .open: "回答を待っています"
        case .clarifying: "説明を作っています"
        case .answered: "回答済み（\(question.answer?.choice.map(plain) ?? "自由記述")）"
        case .dropped: "要らなくなりました"
        }
    }

    private static func kind(of caution: Caution) -> String {
        switch caution.kind {
        case .security: "セキュリティ"
        case .privacy: "個人のデータ"
        case .irreversible: "取り消せない変更"
        case .cost: "お金がかかる"
        }
    }

    private static func task(_ task: GoalFile.Task) -> String {
        let detail = task.detail.map { ": \(plain($0))" } ?? ""
        let premise = task.dependsOn.isEmpty ? "" : "（前提: \(task.dependsOn.joined(separator: "・"))）"
        let state = switch task.state {
        case .pending: ""
        case .locked: "【人がする作業の待ち】"
        case .running: "【実装中】"
        case .done: "【済み】"
        }
        return "- \(state)\(task.id). \(plain(task.title))\(detail)\(premise)"
    }

    private static func humanTask(_ task: GoalFile.HumanTask) -> [String] {
        let state = task.state == .done ? "【済み】" : ""
        return ["- \(state)\(task.id). \(plain(task.title)): \(plain(task.why))"]
            + task.steps.enumerated().map { "  \($0.offset + 1). \(plain($0.element))" }
    }

    private static func section(_ title: String, _ items: [String]) -> [String] {
        ["", "### \(title)", ""] + (items.isEmpty ? ["（なし）"] : items)
    }

    /// 人と Claude の書いた文。HTML のコメントの始まりを崩し、続く本文と目印が隠れないようにする。
    /// `@` の直後に見えない文字（U+2060）を入れ、メンションにしない（写しのたびに、関係の無い人へ通知が飛ばないように。
    /// Claude の文は、リポジトリの中の文章に誘導されて人の名前を書くこともある）
    static func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "<!--", with: "&lt;!--").replacingOccurrences(of: "@", with: "@\u{2060}")
    }

    /// 引用にする（空の行も引用の中に入れる）
    static func quoted(_ text: String) -> String {
        plain(text)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? ">" : "> \($0)" }
            .joined(separator: "\n")
    }

    /// 長すぎれば切る
    static func truncated(_ body: String) -> String {
        guard body.unicodeScalars.count > maximumLength else { return body }
        return String(String.UnicodeScalarView(body.unicodeScalars.prefix(maximumLength)))
            + "\n\n（長いので、ここで切りました。全体は AskHub のアプリで見られます）"
    }
}
