import AskHubProtocol
import Foundation

/// Claude に頼まれたビルドとテストを流した結果。`summary` は、トークンらしい文字列を伏せてから入れる（Claude に渡し、往復を使い切ったときは試行のログの抜粋にもなる）
public enum TaskBuildResult: Equatable, Sendable {
    /// 通った。`summary` は警告などの要約
    case passed(summary: String)
    /// ビルドかテストが落ちた。`summary` はエラーと落ちたテストの抜粋。Claude に渡して直させる
    case failed(summary: String)
    /// 流せなかった（Simulator を用意できない・時間切れ・コマンドが見つからないなど）。Claude の誤りではないので、渡さずに試行の失敗にする
    case couldNotRun(AttemptFailure)
}

/// ビルドとテストを流す部品。Claude Code の sandbox の中では動かないので、ワーカーが sandbox の外で決まったコマンドを流す（`docs/renewal/flows.md` の「Claude にビルドとテストを頼ませる」）。
///
/// 中身は `AskHubBuild` が持つ。ここでは、Claude との往復から呼べる形だけを決める。
/// 何を流すかは、リポジトリの `repo.json` の `build`（`AskHubBuild` の `BuildSettings`）で決まる
public protocol BuildService: Sendable {
    func run(_ kind: TaskReport.BuildKind) async -> TaskBuildResult
}
