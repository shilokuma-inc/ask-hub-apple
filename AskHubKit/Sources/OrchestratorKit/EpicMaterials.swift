import Foundation

/// GitHub 上で集めた、epic の最終 PR の材料。制御用 worktree の「最終 PR に載せる内容」が使えないときに使う
public struct EpicMaterials: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let number: Int
        public let title: String

        public init(number: Int, title: String) {
            self.number = number
            self.title = title
        }
    }

    /// epic にマージされた子 PR
    public let mergedPullRequests: [Item]
    /// epic 宛てでまだ open の子 PR（回答待ちなど）
    public let openPullRequests: [Item]
    /// 本文かタイトルで epic に触れている、open な仮決め一覧（`decision-log`）
    public let decisionLogs: [Item]
    /// 本文かタイトルで epic に触れている、open な実機確認（`needs-verify`）
    public let verifyIssues: [Item]

    public init(mergedPullRequests: [Item], openPullRequests: [Item], decisionLogs: [Item], verifyIssues: [Item]) {
        self.mergedPullRequests = mergedPullRequests
        self.openPullRequests = openPullRequests
        self.decisionLogs = decisionLogs
        self.verifyIssues = verifyIssues
    }

    /// 最終 PR を作れない（取り込むものが無い）
    public var isEmpty: Bool {
        mergedPullRequests.isEmpty
    }

    /// GitHub の情報から最終 PR を作る理由
    public enum Reason: Sendable, Equatable {
        /// 手動ループ（`manual-loop`）の epic。オーケストレーターは制御用 worktree を見られない
        case manualLoop
        /// ループが state の「最終 PR に載せる内容」を書かずに終わった
        case summaryMissing

        var note: String {
            switch self {
            case .manualLoop:
                "手動ループ（`manual-loop`）で回した epic のため、制御用 worktree の内容は使えない"

            case .summaryMissing:
                "ループが state の「最終 PR に載せる内容」を書かずに終わった"
            }
        }
    }

    /// 最終 PR の本文（ゴール元の Discussion の目印は `EpicSnapshot.pullRequestBody` が先頭に足す）
    public func summary(branch: String, discussion: Int?, reason: Reason) -> String {
        func list(_ items: [Item]) -> String {
            items.isEmpty ? "- なし" : items.map { "- #\($0.number) \($0.title)" }.joined(separator: "\n")
        }
        let source = discussion.map { "Discussion #\($0) への対応をまとめた" } ?? "ループで実装した"
        return """
            ### 概要
            \(source) epic（`\(branch)`）。

            ※ \(reason.note)ので、オーケストレーターが GitHub 上の子 PR と Issue から作った。

            ### 含まれる PR
            \(list(mergedPullRequests))

            ### 回答待ちの PR（epic にまだマージされていない子 PR）
            \(list(openPullRequests))

            ### 判断ログ（返答のない decision は既定値のまま確定する）
            \(list(decisionLogs))

            ### 実機確認 Issue
            \(list(verifyIssues))
            """
    }
}
