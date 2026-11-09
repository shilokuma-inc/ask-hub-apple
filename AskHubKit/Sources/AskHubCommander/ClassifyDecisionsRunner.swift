import AskHubProtocol
import Foundation

/// 判断の仕分け（`classifyDecisions`）を 1 回実行する（`docs/renewal/flows.md` の「最終 PR までの段取り」）。常時オンの Mac で動く。
///
/// 読むだけのレビュー役の Claude が、`decisions.json` の仮決めと epic 全体の差分を読み、見える（挙動・仕様・見た目に関わる）仮決めを選ぶ。
/// 見えるとした id を `outputs.visibleDecisions` に書く（ここに無いものは内部の細部。`decisions.json` には司令塔が写す）。
/// 撮影の設定があれば、見える仮決めごとに撮る画面も選ばせて `outputs.decisionScenes` に書く。
///
/// 仕分けたものは仕分け直さない。見えるとしたものはそのまま見えるものとして返し（人の答えがあるものを内部にしない）、
/// 仕分ける前のもの（`visible` が nil）だけを Claude に聞く
public struct ClassifyDecisionsRunner: JobRunning {
    public var environment: FinalJobEnvironment

    public init(environment: FinalJobEnvironment) {
        self.environment = environment
    }

    public func execute(_ job: JobFile) async throws(CommanderError) -> JobResult {
        try await environment.perform(job, as: .classifyDecisions) { target throws(TaskJobExit) in
            try await classify(job, target)
        }
    }

    private func classify(_ job: JobFile, _ target: FinalTarget) async throws(TaskJobExit) -> JobResult {
        let decisions = try await environment.tasks.read(DecisionsFile.self, at: StatePath.decisions(job.repo, job.epic))
        let items = decisions?.items ?? []
        let pending = items.filter { $0.visible == nil }
        guard !pending.isEmpty else {
            return JobResult(outputs: AttemptFile.Outputs(visibleDecisions: items.filter { $0.visible == true }.map(\.id)))
        }
        let expected = pending.map(\.id)
        let (answer, head) = try await environment.withFinalCheckout(job, target: target, head: nil) { checkout throws(TaskJobExit) in
            // 撮影の設定があれば、作業ブランチの先頭の撮れる画面の一覧から、見える仮決めごとに撮る画面を選ばせる
            let scenes = target.settings.screenshots.flatMap { ScreenshotScenes.load(from: checkout.directory, path: $0.scenes).file }
            let subject = DecisionClassification.Subject(
                goal: target.goal, items: pending, branches: target.branches, checkout: checkout, scenes: scenes
            )
            guard let request = DecisionClassification.request(for: subject, repository: job.repo) else {
                let message = "ゴールと仮決めの文が長すぎて、仕分けをレビュー役の Claude に頼めない（決まりの文と合わせて UTF-8 で \(TaskReview.maximumTextBytes) バイトまで）"
                throw .fail(.unexpected, message)
            }
            let answer = try await environment.ask(request, as: DecisionClassificationResult.self) { result in
                result.problems(expected: expected, scenes: scenes)
            }
            return (answer, checkout.head)
        }
        let visible = Set(items.filter { $0.visible == true }.map(\.id) + answer.result.decisions.filter(\.visible).map(\.id))
        let scenes = answer.result.scenes
        let outputs = AttemptFile.Outputs(
            commit: head,
            visibleDecisions: items.map(\.id).filter(visible.contains),
            decisionScenes: scenes.isEmpty ? nil : scenes
        )
        return JobResult(outputs: outputs, claude: answer.session.attemptRecord)
    }
}
