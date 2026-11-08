import AskHubProtocol
import Foundation

/// 判断のカードへの答え（`decision`）を受け付ける（`docs/renewal/flows.md` の「人が決めていない判断の確認」）。
///
/// 見えると仕分けた仮決めで、人が見た head（`targetVersion`）が今の最終 PR の head と同じときだけ、`decisions.json` に答えを書く。
/// 「別案にする」「直してほしい」は、最終 PR の直し（`fixFinalPullRequest`、理由は `human`、元の人の意図はこの答え）を作り、epic を `finalizing` に戻す。
/// 直しが済んだら、司令塔がこの答えを外して、直った後を見て答え直してもらう（`TaskFlow.fixed`）
public struct DecisionHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let decision: DecisionIntent
        do {
            decision = try DecisionIntent(envelope: envelope)
        } catch {
            return .reject("判断のカードへの答えの形が違う（\(error.detail)）")
        }
        let target = decision.target
        let decisions = try await context.read(DecisionsFile.self, at: StatePath.decisions(target.repo, target.epic))
        guard let item = decisions?.items.first(where: { $0.id == target.decision }) else {
            return .reject("判断のカード \(target.decision) が無い")
        }
        // 前の周で答えを書いた（やり直し）。直しまで作っていれば（OK なら答えを書いていれば）済んでいる
        let answered = item.answer?.intent == decision.intent
        let fixOrigin = decision.answer == .ok ? nil : decision.intent
        if answered, try await FinalPullRequestState.applied(fixOrigin, in: context, target.repo, target.epic) { return .accept }
        let state: FinalPullRequestState
        switch try await FinalPullRequestState.read(target.repo, epic: target.epic, head: target.head, in: context) {
        case let .rejected(reason): return .reject(reason)
        case let .found(found): state = found
        }
        if let problem = problem(answering: item, with: decision, answered: answered, state: state) { return .reject(problem) }
        if !answered { try await write(decision, to: state.epic, in: context) }
        if decision.answer != .ok { try await state.startHumanFix(origin: decision.intent) }
        return .accept
    }

    /// 答えられない理由。答えられれば nil
    private func problem(
        answering item: DecisionsFile.Item,
        with decision: DecisionIntent,
        answered: Bool,
        state: FinalPullRequestState
    ) -> String? {
        switch item.visible {
        case nil: return "判断のカード \(item.id) はまだ仕分けていない"
        case false?: return "\(item.id) は内部の細部の仮決めで、答えるカードでない"
        case true?: break
        }
        // 同じカードへの答え直しは受け付けない（変えたいときは、最終 PR への指示を出す）
        if !answered, item.answer != nil { return "判断のカード \(item.id) にはもう答えている。変えたいときは、最終 PR への指示を出す" }
        // 直させる答えは、最後のレビューの後に直し・マージが動いていないときだけ受け付ける（直しを重ねると、head を固定できない）
        if decision.answer != .ok, !state.chain.endsWithReview { return FinalPullRequestState.busy }
        return nil
    }

    private func write(_ decision: DecisionIntent, to epic: EpicFile, in context: CommanderContext) async throws(CommanderError) {
        let target = decision.target
        let answer = DecisionsFile.Answer(choice: decision.answer, note: decision.note, intent: decision.intent, at: context.timestamp)
        let written = try await context.updateDecisions(of: epic, message: "判断のカード \(target.decision) に答える") { file in
            guard let index = file.items.firstIndex(where: { $0.id == target.decision }), file.items[index].visible == true,
                  file.items[index].answer == nil else { return false }
            file.items[index].answer = answer
            return true
        }
        // 読んだ後に書き換わった。次の周で読み直して決める
        guard written else { throw .changedWhileProcessing(StatePath.decisions(target.repo, target.epic)) }
    }
}

/// 最終 PR のマージの承認（`approveMerge`）を受け付け、承認した head を固定したマージ（`mergeFinalPullRequest`）を作る。
///
/// 人の確認を待っている（`reviewing`）epic で、最終 PR のレビューが通り、見える仮決めのすべてに答えがあり、直しが動いていないときだけ受け付ける。
/// 承認は人が見た head（`targetVersion`）に結びつくので、head が進んでいたら断る（新しい head を見て承認し直してもらう）
public struct ApproveMergeHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let approve: ApproveMergeIntent
        do {
            approve = try ApproveMergeIntent(envelope: envelope)
        } catch {
            return .reject("マージの承認の形が違う（\(error.detail)）")
        }
        let target = approve.target
        // 前の周でマージを作った（やり直し）
        let mergeID = CommanderContext.jobID(.mergeFinalPullRequest, origin: approve.intent, seed: "")
        if try await context.read(JobFile.self, at: StatePath.job(target.repo, epic: target.epic, job: mergeID)) != nil { return .accept }
        let state: FinalPullRequestState
        switch try await FinalPullRequestState.read(target.repo, epic: target.epic, head: target.head, in: context) {
        case let .rejected(reason): return .reject(reason)
        case let .found(found): state = found
        }
        guard state.epic.stage == .reviewing else { return .reject("マージを承認できる段階でない（今は \(state.epic.stage.rawValue)）") }
        guard state.chain.endsWithReview else { return .reject(FinalPullRequestState.busy) }
        guard state.review.state == .succeeded, try await context.succeededOutputs(of: state.review)?.verdict == .ready else {
            return .reject("最終 PR のレビューが通っていない")
        }
        let decisions = try await context.read(DecisionsFile.self, at: StatePath.decisions(target.repo, target.epic))
        guard FinalMergeRule.canApprove(decisions: decisions) else {
            let open = decisions?.items.filter { $0.visible != false && $0.answer == nil }.map(\.id) ?? []
            return .reject("答えていない判断のカードがある（\(open.joined(separator: "・"))）。すべてに答えてから承認する")
        }
        // 承認した head を固定してマージする（承認の後に push された変更は入れない）
        let input = state.reviewed
        let merge = try await state.jobs.job(.mergeFinalPullRequest, input: input, after: state.review, origin: approve.intent, seed: "")
        try await context.create(merge)
        return .accept
    }
}

/// 最終 PR への指示（`instructFinal`）を受け付け、人の文で直させる（`fixFinalPullRequest`、理由は `human`）。epic を `finalizing` に戻す。
///
/// 人が見た head（`targetVersion`）が今の最終 PR の head と同じで、最後のレビューの後に直し・マージが動いていないときだけ受け付ける
public struct InstructFinalHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let instruct: InstructFinalIntent
        do {
            instruct = try InstructFinalIntent(envelope: envelope)
        } catch {
            return .reject("最終 PR への指示の形が違う（\(error.detail)）")
        }
        let target = instruct.target
        // 前の周で直しを作った（やり直し）
        if try await FinalPullRequestState.applied(instruct.intent, in: context, target.repo, target.epic) { return .accept }
        let state: FinalPullRequestState
        switch try await FinalPullRequestState.read(target.repo, epic: target.epic, head: target.head, in: context) {
        case let .rejected(reason): return .reject(reason)
        case let .found(found): state = found
        }
        guard state.chain.endsWithReview else { return .reject(FinalPullRequestState.busy) }
        try await state.startHumanFix(origin: instruct.intent)
        return .accept
    }
}

/// 最終 PR を対象にする人の意図の処理で読むもの（epic・段取りのジョブの並び・最後のレビュー）
struct FinalPullRequestState {
    var context: CommanderContext
    var epic: EpicFile
    var chain: FinalChain
    var jobs: FinalJobs
    /// 最後の最終 PR のレビュー
    var review: JobFile
    /// 最後のレビューが見た最終 PR と head（今の head）
    var reviewed: PullRequestInput

    enum Loaded {
        case found(FinalPullRequestState)
        case rejected(String)
    }

    static let busy = "最終 PR を直している・マージしている途中。終わってから、新しい head を見て送り直す"

    /// 対象の epic を読み、人が見た `head` が今の最終 PR の head と同じかを確かめる
    static func read(
        _ repo: RepositoryFullName,
        epic id: ULID,
        head: String,
        in context: CommanderContext
    ) async throws(CommanderError) -> Loaded {
        guard let epic = try await context.read(EpicFile.self, at: StatePath.epic(repo, id)) else { return .rejected("epic が無い") }
        guard [.finalizing, .reviewing].contains(epic.stage) else { return .rejected("最終 PR の段階でない（今は \(epic.stage.rawValue)）") }
        let list = try await context.jobList(repo, epic: id)
        guard list.unreadable.isEmpty else { return .rejected("読めないジョブがあり、最終 PR の段取りを確かめられない（司令塔を新しくする）") }
        let chain = FinalChain(jobs: list.jobs)
        guard chain.ordered != nil else { return .rejected("最終 PR の段取りのジョブが 1 本の列になっていない") }
        guard let review = chain.latestReview, let reviewed = chain.reviewed, let jobs = FinalJobs(context: context, epic: epic) else {
            return .rejected("最終 PR のレビューがまだ無い")
        }
        guard reviewed.head == head else {
            return .rejected("最終 PR の head が変わった（今は \(reviewed.head.prefix(7))）。新しい head を見てから送り直す")
        }
        return .found(FinalPullRequestState(context: context, epic: epic, chain: chain, jobs: jobs, review: review, reviewed: reviewed))
    }

    /// 人の文で直させる直しのジョブの id（元の人の意図ごとに 1 つ）
    static func humanFixID(_ origin: IntentReference) -> ULID {
        CommanderContext.jobID(.fixFinalPullRequest, origin: origin, seed: "")
    }

    /// 前の周で、この人の意図の直しまで作ったか（`origin` が nil なら、直しは作らないので済んでいる）。
    /// 直しが動いていれば、epic を `finalizing` に戻すところまで書く
    static func applied(
        _ origin: IntentReference?,
        in context: CommanderContext,
        _ repo: RepositoryFullName,
        _ epicID: ULID
    ) async throws(CommanderError) -> Bool {
        guard let origin else { return true }
        let path = StatePath.job(repo, epic: epicID, job: humanFixID(origin))
        guard let fix = try await context.read(JobFile.self, at: path) else { return false }
        if JobFile.openStates.contains(fix.state), let epic = try await context.read(EpicFile.self, at: StatePath.epic(repo, epicID)) {
            try await context.setStage(.finalizing, of: epic, from: [.reviewing])
        }
        return true
    }

    /// 最後のレビューが見た head で、人の文で直させる直しを作り、epic を `finalizing` に戻す（人の確認の待ちをやめ、レビューからやり直す）
    func startHumanFix(origin: IntentReference) async throws(CommanderError) {
        let input = FixTaskInput(pullRequest: reviewed.pullRequest, head: reviewed.head, reason: .human)
        let fix = try await jobs.job(.fixFinalPullRequest, input: input, after: review, origin: origin, seed: "")
        try await context.create(fix)
        try await context.setStage(.finalizing, of: epic, from: [.reviewing])
    }
}
