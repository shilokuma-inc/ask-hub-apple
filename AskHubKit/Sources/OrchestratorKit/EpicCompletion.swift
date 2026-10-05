import Foundation

/// 制御用 worktree から読んだ、epic の進み具合
public struct EpicSnapshot: Sendable, Equatable {
    /// 制御用 worktree が checkout しているブランチ（例: `epic/mvp`）。detached や読めないときは `nil`
    public let branch: String?
    /// `.claude/ralph-goal.local.md` の内容。無ければ `nil`
    public let goal: String?
    /// `.claude/ralph-state.local.md` の内容。無ければ `nil`
    public let state: String?
    /// ゴール元の Discussion の番号。起動スクリプトが `.claude/askhub-bootstrap.local.txt` に残す。
    /// 手で始めた epic など、記録が無ければ `nil`
    public let discussion: Int?
    /// ループを始められる状態まで準備した（起動スクリプトが完了語を `.claude/askhub-promise.local.txt` に残した）
    public let loopPrepared: Bool
    /// 準備の結果 goal にタスクが無かった Discussion の番号（起動スクリプトが `.claude/askhub-no-tasks.local.txt` に残す）
    public let noTasksDiscussion: Int?

    public init(
        branch: String?,
        goal: String?,
        state: String?,
        discussion: Int? = nil,
        loopPrepared: Bool = false,
        noTasksDiscussion: Int? = nil
    ) {
        self.branch = branch
        self.goal = goal
        self.state = state
        self.discussion = discussion
        self.loopPrepared = loopPrepared
        self.noTasksDiscussion = noTasksDiscussion
    }

    /// 途中の epic がある（準備を終えた `epic/` のブランチに、回答待ちでない未完了のタスクが残っている）。
    /// 1 リポジトリにつきループは 1 つなので、新しい epic はこれが終わるまで始めない
    public var inProgress: Bool {
        loopPrepared && branch?.hasPrefix("epic/") == true && goal.map(EpicCompletion.hasUnfinishedTasks(in:)) == true
    }

    /// 最終 PR の本文。ゴール元の Discussion があれば、先頭にその番号と機械が読める目印を置く
    /// （最終 PR がマージされたら、ワークフローがこの目印を読んで Discussion を閉じる）
    public static func pullRequestBody(summary: String, discussion: Int?) -> String {
        guard let discussion else {
            return summary
        }
        return "ゴール元: Discussion #\(discussion)\n<!-- ask-hub:discussion \(discussion) -->\n\n\(summary)"
    }

    /// PR の本文の先頭に、`discussion` の目印があるか。
    /// ワークフロー（close-goal-discussion.yml）と同じく、1 行目の見出しと 2 行目の目印の番号が一致するときだけ認める
    public static func hasDiscussionMarker(_ body: String?, discussion: Int) -> Bool {
        let lines = (body ?? "").replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
        return lines.count >= 2
            && lines[0] == "ゴール元: Discussion #\(discussion)"
            && lines[1] == "<!-- ask-hub:discussion \(discussion) -->"
    }
}

/// epic が完了して、develop 向けの最終 PR を作ってよいか（副作用なし）
public enum EpicCompletion: Sendable, Equatable {
    /// 完了した。`summary` は state の「最終 PR に載せる内容」
    case complete(branch: String, summary: String)
    case incomplete(Reason)

    public enum Reason: Sendable, Equatable {
        /// ループが動いている、または state ファイルの有無を確かめられない
        case loopActive
        /// 制御用 worktree のブランチが `epic/` で始まらない
        case notEpicBranch
        /// ゴールファイルが無い、または未完了のタスクが残っている
        case tasksRemain
        /// 「最終 PR に載せる内容」が埋まっていない（ループが promise を出す前）
        case summaryMissing
    }

    /// 最終 PR の本文を書く state の見出し
    static let summaryHeading = "## 最終 PR に載せる内容"
    /// 回答待ちのタスク。ループには完了扱いにできないので、残っていても epic は終えてよい
    static let waitingMark = "※回答待ち"

    public init(snapshot: EpicSnapshot, status: LoopStatus) {
        guard !status.processAlive, status.stateFileExists == false else {
            self = .incomplete(.loopActive)
            return
        }
        guard let branch = snapshot.branch, branch.hasPrefix("epic/") else {
            self = .incomplete(.notEpicBranch)
            return
        }
        guard let goal = snapshot.goal, !Self.hasUnfinishedTasks(in: goal) else {
            self = .incomplete(.tasksRemain)
            return
        }
        guard let summary = snapshot.state.flatMap(Self.summary(in:)) else {
            self = .incomplete(.summaryMissing)
            return
        }
        self = .complete(branch: branch, summary: summary)
    }

    /// `- [ ]` のタスクのうち、回答待ちでないものがあるか
    static func hasUnfinishedTasks(in goal: String) -> Bool {
        goal.split(whereSeparator: \.isNewline).contains { line in
            line.trimmingCharacters(in: .whitespaces).hasPrefix("- [ ]") && !line.contains(waitingMark)
        }
    }

    /// state の「最終 PR に載せる内容」の節。HTML コメントを除いて空なら `nil`
    static func summary(in state: String) -> String? {
        let lines = state.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == summaryHeading }) else {
            return nil
        }
        let body = lines[(start + 1)...].prefix { !$0.hasPrefix("## ") }.joined(separator: "\n")
        let text = body
            .replacing(/<!--[\s\S]*?-->/, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
