import AskHubClaude
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
        // 撮影の設定があって、epic 全体の画面の変化をまだ選んでいなければ、仮決めが無くても選ばせる
        let choosesScreens = target.settings.screenshots != nil && decisions?.screens == nil
        let visibleIDs = items.filter { $0.visible == true }.map(\.id)
        guard !pending.isEmpty || choosesScreens else {
            return JobResult(outputs: AttemptFile.Outputs(visibleDecisions: visibleIDs))
        }
        let expected = pending.map(\.id)
        typealias Answer = (result: DecisionClassificationResult, session: ClaudeSession)
        let checkedOut: (Answer?, String) = try await environment.withFinalCheckout(
            job, target: target, head: nil
        ) { checkout throws(TaskJobExit) in
            // 撮影の設定があれば、作業ブランチの先頭の撮れる画面の一覧から、見える仮決めごとに撮る画面と、画面の変化を選ばせる
            let scenes = target.settings.screenshots.flatMap { ScreenshotScenes.load(from: checkout.directory, path: $0.scenes).file }
            // 仕分ける仮決めが無く、選べる画面も無い（一覧が読めない）なら、Claude を呼ばずに「画面の変化は無い」とする
            guard !pending.isEmpty || scenes != nil else { return (nil, checkout.head) }
            let subject = DecisionClassification.Subject(
                goal: target.goal,
                items: pending,
                branches: target.branches,
                checkout: checkout,
                scenes: scenes,
                choosesScreens: choosesScreens
            )
            guard let request = DecisionClassification.request(for: subject, repository: job.repo) else {
                let message = "ゴールと仮決めの文が長すぎて、仕分けをレビュー役の Claude に頼めない（決まりの文と合わせて UTF-8 で \(TaskReview.maximumTextBytes) バイトまで）"
                throw .fail(.unexpected, message)
            }
            let answer: Answer = try await environment.ask(request, as: DecisionClassificationResult.self) { result in
                result.problems(expected: expected, scenes: scenes)
            }
            return (answer, checkout.head)
        }
        let (answer, head) = checkedOut
        let result = answer?.result
        let visible = Set(visibleIDs + (result?.decisions ?? []).filter(\.visible).map(\.id))
        let scenes = result?.scenes ?? [:]
        let outputs = AttemptFile.Outputs(
            commit: head,
            visibleDecisions: items.map(\.id).filter(visible.contains),
            decisionScenes: scenes.isEmpty ? nil : scenes,
            changedScenes: choosesScreens ? result?.changedScenes ?? [] : nil
        )
        return JobResult(outputs: outputs, claude: answer?.session.attemptRecord)
    }
}
