import AskHubProtocol
import Foundation

/// すべてのタスクが済んだ後の、最終 PR の段取り（`docs/renewal/flows.md` の「最終 PR までの段取り」）。
///
/// | 成功したジョブ | すること |
/// | --- | --- |
/// | （タスクがすべて済んだ） | epic を `finalizing` にし、epic の Mac に最終 PR の前の検証を作る |
/// | 検証 | 仕分けていない仮決めがあれば判断の仕分けを、無ければ最終 PR の作成を作る |
/// | 判断の仕分け | 見えるとした仮決めを `decisions.json` に写し、最終 PR の作成（直しの後なら、直した head のレビュー）を作る |
/// | 最終 PR の作成 | 最終 PR を `epic.json` に書き、出した head でレビューを作る |
/// | レビュー（`ready`） | マージの規則で自動ならマージを作る。手動なら epic を `reviewing` にして人を待つ |
/// | レビュー（直す判定） | 直しを作る。自動の直しが上限を超えたら、動かさずに人の対応待ちで作る |
/// | 直し | 仮決めを足し、仕分けていない仮決めがあれば仕分けを、無ければ直した head のレビューを作る |
/// | マージ | 片付けを作り、epic を `merged` にする |
///
/// 撮影（`captureScreenshots`）は、ビルドの設定に撮影の方法があるリポジトリだけで行う。今はどのリポジトリにも無いので作らない
extension TaskFlow {
    /// 最終 PR の段取りに使うもの
    struct FinalPlan {
        var plan: Plan
        var jobs: FinalJobs
        var chain: FinalChain
        var goal: GoalFile

        var epic: EpicFile { plan.epic }
    }

    /// 仕分けの後に作るもの
    enum AfterClassification: Equatable {
        /// 最終 PR を出す（最初の仕分けの後）
        case open
        /// 直した head をレビューする（直しの後の仕分けの後）
        case review(PullRequestInput)
    }

    /// すべてのタスクが済んだ: epic を `finalizing` にしてから、最終 PR の前の検証を作る（作る前に止まっても、次の周で `finalizing` の epic として作る）
    func startFinal(_ goal: GoalFile, plan: Plan, jobs: [JobFile]) async throws(CommanderError) -> Advanced {
        try await context.setStage(.finalizing, of: plan.epic, from: [.running])
        var advanced = try await advanceFinal(goal, plan: plan, jobs: jobs)
        advanced.notes.insert("epic \(plan.epic.id) のタスクがすべて済んだので、最終 PR の段取りに進む", at: 0)
        return advanced
    }

    /// 最終 PR の段取りの、最後のジョブの結果から次のジョブを決める（`finalizing`・`reviewing` の epic）
    func advanceFinal(_ goal: GoalFile, plan: Plan, jobs: [JobFile]) async throws(CommanderError) -> Advanced {
        guard let finalJobs = FinalJobs(context: context, epic: plan.epic) else { return Advanced() }
        let final = FinalPlan(plan: plan, jobs: finalJobs, chain: FinalChain(jobs: jobs), goal: goal)
        guard let ordered = final.chain.ordered else {
            return Advanced(notes: ["epic \(plan.epic.id) の最終 PR の段取りのジョブが 1 本の列になっていない（枝分かれ・途切れ）"])
        }
        guard let leaf = ordered.last else {
            return try await create(.verifyBeforeFinal, input: nil, after: nil, seed: "", in: final)
        }
        // 片付けはマージが成功してから作る。epic を merged にする前に止まったときは、ここで書く
        if leaf.kind == .cleanUp {
            try await context.setStage(.merged, of: plan.epic, from: [.finalizing, .reviewing])
            return Advanced()
        }
        // 動いているジョブを待つ（人の対応待ちを含む）
        guard leaf.state == .succeeded else { return Advanced() }
        return try await next(after: leaf, in: final)
    }

    // MARK: - 次の一手

    /// 成功した最後のジョブの種類ごとに、次のジョブを決める
    func next(after leaf: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        switch leaf.kind {
        case .verifyBeforeFinal: return try await classify(then: .open, after: leaf, in: final)
        case .classifyDecisions: return try await classified(leaf, in: final)
        case .openFinalPullRequest: return try await opened(leaf, in: final)
        case .reviewFinalPullRequest: return try await reviewed(leaf, in: final)
        case .fixFinalPullRequest: return try await fixed(leaf, in: final)
        case .mergeFinalPullRequest: return try await merged(leaf, in: final)
        default: return Advanced(notes: ["epic \(final.epic.id) の最終 PR の段取りに、作らないはずのジョブ（\(leaf.kind.rawValue)）がある"])
        }
    }

    /// 仕分けていない仮決めがあれば判断の仕分けを作り、無ければ `next` を作る
    func classify(then next: AfterClassification, after parent: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        let decisions = try await context.read(DecisionsFile.self, at: StatePath.decisions(final.epic.repo, final.epic.id))
        guard decisions?.hasUnclassified == true else { return try await proceed(to: next, after: parent, in: final) }
        return try await create(.classifyDecisions, input: nil, after: parent, seed: parent.id.rawValue, in: final)
    }

    /// 仕分けの後に作るもの（最終 PR の作成か、直した head のレビュー）を作る
    func proceed(to next: AfterClassification, after parent: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        switch next {
        case .open:
            // 最終 PR は epic に 1 本だけ出す
            return try await create(.openFinalPullRequest, input: nil, after: parent, seed: "", in: final)
        case let .review(input):
            return try await create(.reviewFinalPullRequest, input: input, after: parent, seed: "\(parent.id)/\(input.head)", in: final)
        }
    }

    /// 判断の仕分けが成功した: 見えるとした仮決めを `decisions.json` に写し、仕分けの前のジョブに応じて次を作る
    func classified(_ classify: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        guard let visible = try await succeededOutputs(of: classify)?.visibleDecisions else {
            return stuck(classify, "見えるとした仮決め（visibleDecisions）が無い", in: final)
        }
        try await context.updateDecisions(of: final.epic, message: "仮決めを仕分ける") { file in
            let next = file.classifying(visible: visible)
            guard next != file else { return false }
            file = next
            return true
        }
        guard let parent = final.chain.parent(of: classify), parent.kind == .fixFinalPullRequest else {
            return try await proceed(to: .open, after: classify, in: final)
        }
        guard let input = try await reviewInput(after: parent) else { return stuck(parent, "最終 PR か直した head が無い", in: final) }
        return try await proceed(to: .review(input), after: classify, in: final)
    }

    /// 最終 PR の作成が成功した: 最終 PR を `epic.json` に書き、出した head でレビューを作る
    func opened(_ open: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        let outputs = try await succeededOutputs(of: open)
        guard let pullRequest = outputs?.pullRequest, let head = outputs?.commit else {
            return stuck(open, "最終 PR か head のコミットが無い", in: final)
        }
        try await context.writeFinalPullRequest(pullRequest, to: final.epic)
        return try await proceed(to: .review(PullRequestInput(pullRequest: pullRequest, head: head)), after: open, in: final)
    }

    /// 最終 PR のレビューが成功した: 通ったならマージの規則に当て、直す判定なら直しを作る。
    /// 見ている間に head が進んだ（人が push したなど）ときは、ワーカーが判定を書かずに今の head を返すので、その head でレビューし直す
    func reviewed(_ review: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        guard let outputs = try await succeededOutputs(of: review), let seen = review.input(as: PullRequestInput.self) else {
            return stuck(review, "判定が無い", in: final)
        }
        guard let verdict = outputs.verdict else {
            let moved = outputs.commit.map { PullRequestInput(pullRequest: seen.pullRequest, head: $0) }
            guard let moved, moved.isValid, moved.head != seen.head else { return stuck(review, "判定が無い", in: final) }
            return try await proceed(to: .review(moved), after: review, in: final)
        }
        switch verdict {
        case .ready: return try await ready(review, seen: seen, mergeRisks: outputs.mergeRisks, in: final)
        case .fixCI: return try await fix(after: review, seen: seen, reason: .ci, in: final)
        case .fixReview: return try await fix(after: review, seen: seen, reason: .review, in: final)
        // 子 PR のレビューの判定。最終 PR のレビューには出ないので、壊れた結果として知らせる
        case .merged: return stuck(review, "子 PR の判定（merged）がある", in: final)
        }
    }

    /// 最終 PR が通った: 人の確認が要らなければ見た head でマージを作り、要れば epic を `reviewing` にして人を待つ（承認は `approveMerge`）
    func ready(
        _ review: JobFile,
        seen: PullRequestInput,
        mergeRisks: [MergeRisk]?,
        in final: FinalPlan
    ) async throws(CommanderError) -> Advanced {
        // 人の確認を待っている。マージは人の承認で作る
        guard final.epic.stage == .finalizing else { return Advanced() }
        let decisions = try await context.read(DecisionsFile.self, at: StatePath.decisions(final.epic.repo, final.epic.id))
        let reasons = FinalMergeRule.manualReasons(decisions: decisions, mergeRisks: mergeRisks ?? [])
        // マージの規則の材料が欠けていたら、自動でマージせずに人に確かめてもらう
        if reasons.isEmpty, mergeRisks != nil {
            return try await create(.mergeFinalPullRequest, input: seen, after: review, seed: review.id.rawValue, in: final)
        }
        try await context.setStage(.reviewing, of: final.epic, from: [.finalizing])
        let why = mergeRisks == nil ? "レビューの結果にマージの規則の材料（mergeRisks）が無い" : reasons.map(\.summary).joined(separator: "・")
        return Advanced(notes: ["epic \(final.epic.id) の最終 PR #\(seen.pullRequest) は、人の確認を待つ（\(why)）"])
    }

    /// 最終 PR のレビューが直す判定を出した: 見た head で直しを作る。自動の直しが上限を超えたら、作るが動かさずに人に渡す（人が「やり直す」を送れば、もう 1 回直す）
    func fix(
        after review: JobFile,
        seen: PullRequestInput,
        reason: FixTaskInput.Reason,
        in final: FinalPlan
    ) async throws(CommanderError) -> Advanced {
        let round = final.chain.automaticFixes + 1
        let input = FixTaskInput(pullRequest: seen.pullRequest, head: seen.head, reason: reason)
        let seed = "\(review.id)/\(round)"
        var fix = try await final.jobs.job(.fixFinalPullRequest, input: input, after: review, origin: final.plan.origin, seed: seed)
        guard round > policy.maxFixRounds else {
            try await context.create(fix)
            return Advanced(created: [fix])
        }
        fix.state = .waitingHuman
        try await context.create(fix)
        let note = "epic \(final.epic.id) の最終 PR の直しが上限（\(policy.maxFixRounds) 回）を超えたので、人に渡した（\(fix.id)）"
        return Advanced(created: [fix], notes: [note])
    }

    /// 最終 PR の直しが成功した: 仮決めを足し（人が頼んだ直しなら、その答えを外して答え待ちに戻す）、直した head のレビューを作る。
    /// 直しで仕分けていない仮決めが増えたら、先に仕分ける（仕分ける前の仮決めには答えられず、マージの承認もできないため）
    func fixed(_ fix: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        guard let input = try await reviewInput(after: fix) else { return stuck(fix, "最終 PR か直した head が無い", in: final) }
        if fix.input(as: FixTaskInput.self)?.reason == .human, let origin = fix.origin {
            try await context.updateDecisions(of: final.epic, message: "直した判断のカードを答え待ちに戻す") { file in
                let next = file.reopening(answeredBy: origin)
                guard next != file else { return false }
                file = next
                return true
            }
        }
        // 最終 PR の直しはタスクに結びつかないので、仮決めはゴールの最後のタスクのものとして足す（decisions.json の項目はタスクを持つ）
        if let decisions = try await succeededOutputs(of: fix)?.report?.decisions, let task = final.goal.tasks.last {
            try await addDecisions(decisions, task: task.id, pullRequest: input.pullRequest, epic: final.epic)
        }
        return try await classify(then: .review(input), after: fix, in: final)
    }

    /// 最終 PR をマージした: 片付けを作ってから、epic を `merged` にする（作る前に止まっても、次の周で片付けを作る）
    func merged(_ merge: JobFile, in final: FinalPlan) async throws(CommanderError) -> Advanced {
        var advanced = try await create(.cleanUp, input: nil, after: merge, seed: "", in: final)
        try await context.setStage(.merged, of: final.epic, from: [.finalizing, .reviewing])
        advanced.notes.append("epic \(final.epic.id) の最終 PR をマージした")
        return advanced
    }

    // MARK: - 部品

    /// 直しの後にレビューする最終 PR と、直した head（直しの `outputs.commit`）
    func reviewInput(after fix: JobFile) async throws(CommanderError) -> PullRequestInput? {
        guard let outputs = try await succeededOutputs(of: fix), let head = outputs.commit,
              let pullRequest = outputs.pullRequest ?? fix.input(as: FixTaskInput.self)?.pullRequest else {
            return nil
        }
        let input = PullRequestInput(pullRequest: pullRequest, head: head)
        return input.isValid ? input : nil
    }

    /// 段取りのジョブを作る。元になった人の意図は開始の意図（作業場所の用意のジョブと同じ）
    func create(
        _ kind: JobKind,
        input: (any JobInput)?,
        after parent: JobFile?,
        seed: String,
        in final: FinalPlan
    ) async throws(CommanderError) -> Advanced {
        let job = try await final.jobs.job(kind, input: input, after: parent, origin: final.plan.origin, seed: seed)
        try await context.create(job)
        return Advanced(created: [job])
    }

    /// 結果が欠けていて進められない（ログに出す）
    func stuck(_ job: JobFile, _ problem: String, in final: FinalPlan) -> Advanced {
        Advanced(notes: ["epic \(final.epic.id) の \(job.kind.rawValue)（\(job.id)）の結果に、\(problem)"])
    }
}

extension FinalMergeRule.ManualReason {
    /// ログに出す短い説明
    var summary: String {
        switch self {
        case let .visibleDecisions(count): "見える仮決め \(count) 件"
        case let .risk(risk): "\(risk.kind.rawValue): \(risk.reason)"
        }
    }
}
