import AskHubProtocol
import Foundation

/// 最終 PR の CI の失敗・レビューの必須の指摘・人の文を付けて、Claude に直させる（`fixFinalPullRequest`）。
///
/// 最終 PR はタスクをまたぎ、epic の Mac がオフラインのときは常時オンの Mac で直すので、実装の会話は再開せず、新しい会話で直させる。
/// 直すことは、子 PR の直しと同じ形（`FixTaskJob.Reason.findings` の文）で渡す
public struct FixFinalPullRequestJob: TaskJob {
    public static let kind = JobKind.fixFinalPullRequest

    public var goal: GoalFile
    public var pullRequest: Int
    public var branches: FinalBranches
    public var reason: FixTaskInput.Reason
    /// 直すこと（`FixTaskJob.Reason.findings` の文）
    public var findings: String

    public init(goal: GoalFile, pullRequest: Int, branches: FinalBranches, reason: FixTaskInput.Reason, findings: String) {
        self.goal = goal
        self.pullRequest = pullRequest
        self.branches = branches
        self.reason = reason
        self.findings = findings
    }

    public var resume: String? { nil }

    /// 最終 PR で待つチェックは UI テストを含むので、CI が落ちたときは全部のテストが通るまで done にさせない
    public var failingAtStart: TaskReport.BuildKind? {
        reason == .ci ? .testFull : nil
    }

    public var prompt: String {
        """
        epic の最終 PR #\(pullRequest)（\(branches.epic) → \(branches.base)）を直してください。\(what)
        作業フォルダは作業ブランチ（epic のタスクをすべて実装し終えたもの）の写しです。直すのに要るファイルを読んでから直してください。

        ## ゴール（epic 全体で作るもの）
        \(UntrustedText.block("goal", PromptText.goal(goal)))

        \(material)

        ## 進め方
        \(steps)
        - 直したら needsBuild で確かめ、通ってから done にする
        - 人が決めないと直せないとき（ゴールの決まったこと・やらないことと食い違う、どう直すか決められない）は、直さずに needsQuestion にして、選択肢を出して聞く
        """
    }

    private var what: String {
        switch reason {
        case .ci: "CI が落ちました。落ちたチェックのログの抜粋を読み、原因を直してください。"
        case .review: "レビューで、マージする前に直す必要のある指摘がありました。指摘ごとに直してください。"
        case .human: "人から直してほしいことが届きました。人の文を読み、そのとおりに直してください。"
        }
    }

    private var material: String {
        switch reason {
        case .ci: "## 落ちたチェック\n\(UntrustedText.block("ci-log", findings))"
        case .review: "## 指摘\n\(UntrustedText.block("review", findings))"
        case .human: "## 人の文\n\(UntrustedText.block("instruction", findings))"
        }
    }

    private var steps: String {
        switch reason {
        case .ci:
            """
            - 落ちた原因に関わる所だけを直す
            - 原因が CI の環境（ランナー・ネットワーク・外のサービス）にあり、コードでは直せないと判断したら、直さずに blocked にし、summary に理由を書く
            - done の summary には、何が原因で、何を直したかを書く
            """
        case .review:
            """
            - 指摘に関わる所だけを直す
            - 指摘が誤っている、またはゴールの決まったこと・やらないことと食い違うと判断したら、その指摘は直さずに summary に理由を書く。どの指摘も直せないときは blocked にする
            - done の summary には、指摘ごとに何をしたかを書く
            """
        case .human:
            """
            - 人の文が求めることに関わる所だけを直す
            - done の summary には、人の文のどこを、どう直したかを書く
            """
        }
    }
}
