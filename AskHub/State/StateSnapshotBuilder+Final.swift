import AskHubProtocol
import Foundation

// MARK: - 最終 PR

extension StateSnapshotBuilder {
    /// 最終 PR の段取りに出すジョブの種類（片付けはマージの後で、マージした epic のジョブは読まないので出さない）
    static let finalStepKinds: Set<JobKind> = [
        .verifyBeforeFinal, .classifyDecisions, .captureScreenshots, .openFinalPullRequest,
        .reviewFinalPullRequest, .fixFinalPullRequest, .mergeFinalPullRequest
    ]
    /// スクショの無い判断のカードに出すわけ（撮影の設定 `build.screenshots` が無いリポジトリ）
    static let noScreenshotSetting = "スクショ無し（このリポジトリには撮影の設定が無い）"
    /// 撮る画面を選べなかった（撮れる画面の一覧に合う画面が無い）仮決め
    static let noScene = "スクショ無し（この仮決めが出る画面は、撮れる画面の一覧に無い）"
    /// 撮る画面を選んだが、まだ撮っていない仮決め
    static let screenshotPending = "スクショを撮っています"

    /// 最終 PR の確認。最終 PR を出す前（`finalPullRequest` が無い）と、やめた epic は nil。
    ///
    /// マージの規則と承認できるかは、司令塔と同じ `FinalMergeRule` で決める。この端末が送って司令塔がまだ処理していない判断への答えは、
    /// 答えた結果として先に当ててから決める（答え終えてすぐ承認できるように）
    func finalReview(of epicDocuments: StateDocuments.EpicDocuments, index: inout StateIndex) -> FinalReview? {
        let file = epicDocuments.epic
        guard let number = file.finalPullRequest, [.finalizing, .reviewing, .merged].contains(file.stage) else {
            return nil
        }
        let jobs = epicDocuments.jobs.filter { $0.state != .canceled }
        let head = Self.latest(jobs.filter { $0.kind == .reviewFinalPullRequest })?.input(as: PullRequestInput.self)?.head
        let decisions = answered(epicDocuments.decisions, of: file, head: head)
        let items = decisions?.items ?? []
        let outputs = lastReviewOutputs(of: epicDocuments)
        let reasons = FinalMergeRule.manualReasons(decisions: decisions, mergeRisks: outputs?.mergeRisks ?? [])
        // 通ったレビューが材料（mergeRisks）を返さなかったときは、司令塔は自動でマージせずに人を待つ
        let risksMissing = outputs?.verdict == .ready && outputs?.mergeRisks == nil
        // 判断の一覧を読めなかったときは、空の一覧と区別する（答えていないカードがあるかもしれないので、承認を止める）
        let decisionsUnreadable = documents.failures.contains { $0.source == StatePath.decisions(file.repo, file.id) }
        let manualReasons = Self.manualReasons(reasons) + (risksMissing ? [.risksUnknown] : [])
            + (decisionsUnreadable ? [.decisionsUnreadable] : [])
        let canApprove = !decisionsUnreadable && FinalMergeRule.canApprove(decisions: decisions)
        let capturesScreenshots = documents.repositories.first { $0.repo == file.repo }?.build?.screenshots != nil
        let cards = items.filter { $0.visible != false }.map { card($0, epic: file, capturesScreenshots: capturesScreenshots) }
        let state = finalState(of: file, jobs: jobs, automatic: manualReasons.isEmpty)
        // 司令塔が答えを受け付けるのは、見えると仕分けた仮決めだけ（仕分ける前のものはカードに出すが、答えは送らない）
        let answerable = items.filter { $0.visible == true }
        index.epics[file.id.rawValue]?.final = StateIndex.FinalEntry(
            pullRequest: number,
            head: head,
            decisionIDs: Set(answerable.map(\.id)),
            unansweredDecisionIDs: answerable.filter { $0.answer == nil }.map(\.id),
            canApprove: canApprove,
            isReviewable: state == .reviewable
        )
        return FinalReview(
            pullRequestNumber: number,
            additions: nil,
            deletions: nil,
            headCommit: head,
            reviewedHeadCommit: nil,
            checks: checks(jobs: jobs, outputs: outputs, merged: file.stage == .merged),
            mergePolicy: manualReasons.isEmpty ? .automatic : .manual(manualReasons),
            decisions: cards,
            internalDecisions: items.filter { $0.visible == false }.map(\.what),
            verifications: [],
            state: state,
            acceptsApproval: canApprove
        )
    }

    // MARK: 判断のカード

    /// 処理を待つ判断への答えを当てた判断の一覧。司令塔が受け付ける答えだけを当てる（見た head が今の head と同じで、見えると仕分けた、
    /// まだ答えの無いカード。同じカードへの答え直しは司令塔が断るので、古い順に当てて最初の答えを残す）
    private func answered(_ decisions: DecisionsFile?, of epic: EpicFile, head: String?) -> DecisionsFile? {
        guard var decisions, let head else {
            return decisions
        }
        for envelope in intentsToOverlay().reversed() where envelope.kind == DecisionIntent.kind {
            guard let intent = try? DecisionIntent(envelope: envelope), intent.target.repo == epic.repo, intent.target.epic == epic.id,
                  intent.target.head == head, let offset = decisions.items.firstIndex(where: { $0.id == intent.target.decision }),
                  decisions.items[offset].visible == true, decisions.items[offset].answer == nil else {
                continue
            }
            decisions.items[offset].answer = DecisionsFile.Answer(
                choice: intent.answer,
                note: intent.note,
                intent: intent.intent,
                at: envelope.issuedAt
            )
        }
        return decisions
    }

    private func card(_ item: DecisionsFile.Item, epic: EpicFile, capturesScreenshots: Bool) -> DecisionCard {
        // 最終 PR の直しで足した仮決めは、タスクを持たず、最終 PR を持つ
        let pullRequest = item.pullRequest.map { $0 == epic.finalPullRequest ? "最終 PR #\($0)" : "子 PR #\($0)" }
        let source = if let task = item.task {
            [taskName(task, epic: epic.id), pullRequest].compactMap(\.self)
        } else {
            [pullRequest.map { "\($0) の直し" } ?? "最終 PR の直し"]
        }
        return DecisionCard(
            id: item.id,
            title: item.what,
            reason: item.why,
            goalSource: source.isEmpty ? nil : source.joined(separator: " · "),
            alternatives: item.alternatives,
            before: item.screenshots?.before.map(Screenshot.stored),
            after: item.screenshots?.after.map(Screenshot.stored),
            response: Self.response(item.answer),
            screenshotNote: Self.screenshotNote(of: item, capturesScreenshots: capturesScreenshots)
        )
    }

    /// スクショに添えるわけ（撮れなかった・Before が無い）。撮ったものがあって、わけも無ければ nil。
    /// 撮ったものがあれば、撮影の設定を後で外した（・repo.json を読めない）ときも、撮ったときのわけだけを出す
    static func screenshotNote(of item: DecisionsFile.Item, capturesScreenshots: Bool) -> String? {
        if let shots = item.screenshots { return shots.note }
        guard capturesScreenshots else { return noScreenshotSetting }
        return item.scene == nil ? noScene : screenshotPending
    }

    private static func response(_ answer: DecisionsFile.Answer?) -> DecisionCard.Response {
        switch answer?.choice {
        case nil: .pending
        case .ok: .accepted
        // 別案・直してほしいは、司令塔が最終 PR を直させる（直したら、スクショを撮り直して再び出す）
        case .alternative, .fix: .fixing(request: answer?.note ?? "")
        }
    }

    // MARK: マージの規則と状態

    /// 画面のマージの理由。注意の要るパスは 1 つにまとめる
    private static func manualReasons(_ reasons: [FinalMergeRule.ManualReason]) -> [FinalReview.ManualReason] {
        var mapped: [FinalReview.ManualReason] = []
        var sensitivePaths: [String] = []
        for reason in reasons {
            let manual: FinalReview.ManualReason
            switch reason {
            case .visibleDecisions(let count):
                manual = .visibleDecisions(count: count)

            case .risk(let risk):
                switch risk.kind {
                case .security: manual = .security
                case .weakenedTests: manual = .weakenedTests
                case .dataMigration: manual = .dataMigration
                case .sensitivePaths:
                    sensitivePaths.append(risk.reason)
                    continue
                }
            }
            // 同じ種類の材料が 2 つあっても、理由は 1 つだけ出す
            if !mapped.contains(manual) {
                mapped.append(manual)
            }
        }
        if !sensitivePaths.isEmpty {
            mapped.append(.sensitivePaths(sensitivePaths))
        }
        return mapped
    }

    /// マージしたか・マージしているか・人が確かめる段階か。マージを人が承認したかは、司令塔が書いたマージの記録で決める。
    /// 記録の無い（記録を書く前の司令塔がマージした）epic だけは、この端末が送って受け付けられた承認と、マージの規則で決める
    private func finalState(of epic: EpicFile, jobs: [JobFile], automatic: Bool) -> FinalReview.State {
        if epic.stage == .merged, let merge = epic.merge {
            return .merged(at: merge.at.date, automatic: merge.approval == nil)
        }
        if epic.stage == .merged {
            let approved = documents.sentIntents.contains { sent in
                sent.envelope.kind == ApproveMergeIntent.kind && sent.envelope.target?.epic == epic.id && sent.consumed?.result == .accepted
            }
            return .merged(at: epic.updatedAt.date, automatic: automatic && !approved)
        }
        // マージし終えてから司令塔が epic をマージ済みにするまでの間も、マージ中として出す
        let merging = jobs.contains { job in
            job.kind == .mergeFinalPullRequest && (Self.activeJobStates.contains(job.state) || job.state == .succeeded)
        }
        if merging {
            return .merging
        }
        return epic.stage == .reviewing ? .reviewable : .checking
    }

    // MARK: チェック

    /// 最後に終わった最終 PR のレビューの結果（判定・直すこと・マージの規則の材料）
    private func lastReviewOutputs(of epicDocuments: StateDocuments.EpicDocuments) -> AttemptFile.Outputs? {
        guard let review = StateReader.lastFinishedReview(in: epicDocuments.jobs) else {
            return nil
        }
        return epicDocuments.attempts[review.id]?.last { $0.number == review.attempts }?.outputs
    }

    /// CI とレビューの要約。最後のレビュー・直しのジョブと、最後に終わったレビューの判定から決める
    private func checks(jobs: [JobFile], outputs: AttemptFile.Outputs?, merged: Bool) -> FinalChecks {
        var checks = FinalChecks(ci: merged ? .passed : .reviewing, requiredFindings: 0, securityFindings: 0, hasConflict: false)
        let flow = jobs.filter { [.reviewFinalPullRequest, .fixFinalPullRequest].contains($0.kind) }
        guard !merged, let current = Self.latest(flow) else {
            return checks
        }
        // 直した回は、CI・レビュー・コンフリクトの直しだけを数える（人が頼んだ直しと、実装の途中の質問の答えで再開した直しは 3 回の上限に数えない）
        let automaticFixes = flow.filter(Self.isAutomaticFix)
        switch (current.kind, current.state) {
        case (_, .failed), (_, .waitingHuman):
            checks.ci = .failed
            checks.findings = outputs?.findings

        case (.reviewFinalPullRequest, .succeeded):
            // 直す判定なら、司令塔が直しのジョブを作るまでの間も、次の直しとして出す
            checks.ci = Self.ci(after: outputs?.verdict, nextRound: automaticFixes.count + 1) ?? checks.ci
            checks.findings = outputs?.verdict == .ready ? nil : outputs?.findings
            checks.hasConflict = outputs?.verdict == .fixConflict

        case (.fixFinalPullRequest, let state) where state != .succeeded:
            let reason = Self.finalFixReason(of: current)
            let round = automaticFixes.filter { ($0.createdAt, $0.id.rawValue) <= (current.createdAt, current.id.rawValue) }.count
            checks.ci = Self.fixingCI(reason, round: round)
            checks.findings = reason?.isAutomatic == true ? outputs?.findings : nil
            checks.hasConflict = reason == .conflict

        default:
            // レビューを待っている・直し終えて次のレビューを待っている
            break
        }
        return checks
    }

    /// 最終 PR のレビューの判定のあとの CI の要約。判定が分からなければ nil
    private static func ci(after verdict: ReviewVerdict?, nextRound: Int) -> FinalChecks.CIState? {
        switch verdict {
        case .ready: .passed
        case .fixCI: .fixing(.build, attempt: nextRound)
        case .fixReview: .fixing(.review, attempt: nextRound)
        case .fixConflict: .fixing(.conflict, attempt: nextRound)
        case .merged, nil: nil
        }
    }

    /// 最終 PR の直しの間の CI の要約（何回目か）
    private static func fixingCI(_ reason: FixTaskInput.Reason?, round: Int) -> FinalChecks.CIState {
        switch reason {
        case .ci: .fixing(.build, attempt: round)
        case .review: .fixing(.review, attempt: round)
        case .conflict: .fixing(.conflict, attempt: round)
        case .human, nil: .fixingByRequest
        }
    }

    /// 自動の直しの段取りの理由（何回目か）
    private static func automaticFix(_ reason: FixTaskInput.Reason, round: Int) -> FinalStep.FixReason {
        switch reason {
        case .ci: .checks(round: round)
        case .conflict: .conflict(round: round)
        // 人が頼んだ直しは自動の直しでないので来ない
        case .review, .human: .review(round: round)
        }
    }

    private static func finalFixReason(of job: JobFile) -> FixTaskInput.Reason? {
        job.input(as: FixTaskInput.self)?.reason
    }

    /// CI・レビュー・コンフリクトの直し（人が頼んだ直しと、実装の途中の質問の答えで再開した直しを除く）
    private static func isAutomaticFix(_ job: JobFile) -> Bool {
        job.kind == .fixFinalPullRequest && finalFixReason(of: job)?.isAutomatic == true && !resumesQuestion(job)
    }

    // MARK: 段取り

    /// ジョブが表す最終 PR の段取り。最終 PR の段取りのジョブでなければ nil
    func finalStep(of job: JobFile, jobs: [JobFile]) -> FinalStep? {
        switch job.kind {
        case .verifyBeforeFinal:
            return .verifying

        case .classifyDecisions:
            return .classifying

        case .captureScreenshots:
            return .capturing

        case .openFinalPullRequest:
            return .opening

        case .reviewFinalPullRequest:
            return .reviewing(pullRequest: job.pullRequest)

        case .fixFinalPullRequest:
            guard let reason = Self.finalFixReason(of: job) else {
                return nil
            }
            guard reason.isAutomatic else {
                return .fixing(pullRequest: job.pullRequest, reason: .request)
            }
            // 何回目かは、CI とレビューの直しのうち、これまでに作ったものの数（司令塔が 4 回目から人に渡すのと同じ数え方）
            let round = jobs.filter { Self.isAutomaticFix($0) && ($0.createdAt, $0.id.rawValue) <= (job.createdAt, job.id.rawValue) }.count
            return .fixing(pullRequest: job.pullRequest, reason: Self.automaticFix(reason, round: round))

        case .mergeFinalPullRequest:
            return .merging(pullRequest: job.pullRequest)

        default:
            return nil
        }
    }

    /// 最終 PR の履歴（出した・マージした）
    func finalHistory(of epicDocuments: StateDocuments.EpicDocuments, review: FinalReview?) -> [Epic.HistoryEntry] {
        let file = epicDocuments.epic
        guard let number = file.finalPullRequest else {
            return []
        }
        var entries: [Epic.HistoryEntry] = []
        if let opened = epicDocuments.jobs.first(where: { $0.kind == .openFinalPullRequest && $0.state == .succeeded }) {
            entries.append(Epic.HistoryEntry(date: opened.updatedAt.date, text: "最終 PR #\(number) を出しました"))
        }
        if case let .merged(date, automatic)? = review?.state {
            entries.append(Epic.HistoryEntry(date: date, text: automatic ? "最終 PR #\(number) を自動でマージしました" : "最終 PR #\(number) をマージしました"))
        }
        return entries
    }
}

private extension FixTaskInput.Reason {
    /// CI・レビュー・コンフリクトの直し（人が頼んだ直しでない）
    var isAutomatic: Bool {
        self != .human
    }
}
