import AskHubClient
import AskHubProtocol
import Foundation

/// 画面の人の意図（`HumanIntent`）を、状態リポジトリに送る形（`IntentDraft`）に変える。
///
/// 対象の版（質問・ゴール・着手前の確認の結果）は、最後に読んだ状態（`StateIndex`）から取る。人が見たものの版で送るので、
/// その後に対象が変わっていれば、司令塔が古い意図として断る
struct StateIntentMapper {
    let index: StateIndex

    /// 状態リポジトリに送れる意図か。段階 3 の操作のうち、引き継ぎ・確認・片付けなどは、まだ送れない。
    /// 人に渡されたジョブへの操作は、最後に読んだ状態の「対処が要ります」に出した操作だけ（やり直す・やめる）、取り下げは開始する前の epic だけ、
    /// 最終 PR への操作（判断のカードへの答え・マージの承認・指示）は最終 PR を出した epic だけ送れる
    func supports(_ intent: HumanIntent) -> Bool {
        switch intent {
        case .answer, .requestExplanation, .reviseGoal, .start, .decideSplit, .request, .addRepository:
            true

        case let .resolveBlocker(epicID, action, _, _):
            index.epics[epicID]?.blockerActions.contains(action) == true

        case .discard(let epicID):
            index.epics[epicID]?.canAbandon == true

        case let .respondToDecision(epicID, _, _), let .acceptAllDecisions(epicID), let .merge(epicID, _), let .instructFinal(epicID, _, _):
            index.epics[epicID]?.final != nil

        case .handOver, .pause, .resume, .completeHumanTask, .submitSecret, .verify, .cleanUp:
            false
        }
    }

    /// 送る形。まとめて OK は、答えの無いカードそれぞれへの OK にする（司令塔は判断のカードへの答えを 1 枚ずつ受け取る）
    func drafts(for intent: HumanIntent) throws(ClientServiceError) -> [IntentDraft] {
        guard case .acceptAllDecisions(let epicID) = intent else {
            return [try draft(for: intent)]
        }
        let (epic, final) = try reviewableFinal(epicID)
        guard !final.unansweredDecisionIDs.isEmpty else {
            throw ClientServiceError(message: "まとめて OK にする判断がありません")
        }
        return try final.unansweredDecisionIDs.map { id throws(ClientServiceError) in
            .decision(try decisionTarget(id, epic: epic, final: final), answer: .ok)
        }
    }

    private func draft(for intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case .answer, .requestExplanation:
            return try questionDraft(intent)

        case .reviseGoal, .start, .decideSplit, .discard:
            return try epicDraft(intent)

        case .request, .addRepository:
            return try repositoryDraft(intent)

        case let .resolveBlocker(epicID, action, _, target):
            return try blockerDraft(epicID: epicID, action: action, target: target)

        case .respondToDecision, .merge, .instructFinal:
            return try finalDraft(intent)

        case .acceptAllDecisions, .handOver, .pause, .resume, .completeHumanTask, .submitSecret, .verify, .cleanUp:
            throw Self.unsupported
        }
    }

    private static let unsupported = ClientServiceError(message: "この操作は、まだ状態リポジトリに送れません")

    private func questionDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .answer(epicID, questionID, optionID, note):
            return .answer(try question(questionID, in: epicID), choice: optionID, note: note)

        case let .requestExplanation(epicID, questionID, request):
            return .clarify(try question(questionID, in: epicID), note: request)

        default:
            throw Self.unsupported
        }
    }

    private func epicDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .reviseGoal(epicID, request):
            return .reviseGoal(try goal(of: epicID), instruction: request)

        case let .start(epicID, macID):
            guard let mac = MacName(rawValue: macID) else {
                throw ClientServiceError(message: "Mac の名前の形が違います")
            }
            return .startEpic(try goal(of: epicID), mac: mac)

        case let .decideSplit(epicID, choice):
            let epic = try epic(epicID)
            guard let version = epic.readinessVersion else {
                throw ClientServiceError(message: "着手前の確認の結果がまだありません")
            }
            return .decideSplit(EpicTarget(repo: epic.repo, epic: epic.id, version: version), choice: choice == .split ? .split : .proceed)

        case .discard(let epicID):
            let epic = try epic(epicID)
            guard epic.canAbandon else {
                throw ClientServiceError(message: "開始した epic の取り下げは、まだ送れません")
            }
            return .abandonEpic(repo: epic.repo, epic: epic.id)

        default:
            throw Self.unsupported
        }
    }

    private func repositoryDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .request(repositoryID, summary, body):
            guard summary.count <= RequestIntent.maximumTitleLength, body.count <= RequestIntent.maximumBodyLength else {
                let limits = "要約は \(RequestIntent.maximumTitleLength) 文字、内容は \(RequestIntent.maximumBodyLength) 文字まで"
                throw ClientServiceError(message: "\(limits)です")
            }
            return .request(repo: try repository(repositoryID), title: summary, body: body)

        case .addRepository(let repositoryID):
            // 状態リポジトリにつないだときは候補の一覧が無いので、人が入れた owner/name を id にして送る
            guard let repo = index.repositories[repositoryID] ?? RepositoryFullName(rawValue: repositoryID) else {
                throw ClientServiceError(message: "owner/name の形で入れてください")
            }
            return .addRepository(repo)

        default:
            throw Self.unsupported
        }
    }

    /// 人に渡されたジョブへの操作。人が見たときの試行の番号を付ける（その後に試行が進んでいれば、司令塔が断る）。
    /// 送り直すまでに「対処が要ります」に出すジョブが替わっていたら、別のジョブに当てないよう送らない
    private func blockerDraft(epicID: Epic.ID, action: Blocker.Action, target: String?) throws(ClientServiceError) -> IntentDraft {
        let entry = try epic(epicID)
        guard let job = entry.blockedJob else {
            throw ClientServiceError(message: "対処を待っている作業がありません。取り直してから送ってください")
        }
        guard target == StateSnapshotBuilder.blockerTarget(job), entry.blockerActions.contains(action) else {
            throw ClientServiceError(message: "対処を待っている作業が替わりました。画面を確かめてから選び直してください")
        }
        switch action {
        case .retry, .resumeAfterFix:
            return .retry(job)

        case .cancelJob, .discard:
            return .giveUp(job)

        case .fixWithInstruction, .handOver, .pause:
            throw Self.unsupported
        }
    }

    /// 最終 PR への操作。判断のカードへの答えは最後に読んだ head に、承認と指示は人が見た head に結びつける
    /// （見た後に push された変更には効かない。head が変わっていれば司令塔が断る）
    private func finalDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .respondToDecision(epicID, decisionID, reply):
            let (epic, final) = try reviewableFinal(epicID)
            let target = try decisionTarget(decisionID, epic: epic, final: final)
            switch reply {
            case .accept:
                return .decision(target, answer: .ok)

            case .alternative(let note):
                return .decision(target, answer: .alternative, note: try Self.decisionNote(note))

            case .fix(let note):
                return .decision(target, answer: .fix, note: try Self.decisionNote(note))
            }

        case let .merge(epicID, headCommit):
            let target = try finalTarget(epicID, headCommit: headCommit)
            // 司令塔は、見える仮決めのすべてに答えた後の承認だけを受け付ける（`FinalMergeRule.canApprove`）
            guard index.epics[epicID]?.final?.canApprove == true else {
                throw ClientServiceError(message: "見える仮決めのすべてに答えてから承認してください（判断の一覧を読めていないときは、取り直してください）")
            }
            return .approveMerge(target)

        case let .instructFinal(epicID, headCommit, instruction):
            let text = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= InstructFinalIntent.maximumInstructionLength else {
                throw ClientServiceError(message: "指示は 1〜\(InstructFinalIntent.maximumInstructionLength) 文字で書いてください")
            }
            return .instructFinal(try finalTarget(epicID, headCommit: headCommit), instruction: text)

        default:
            throw Self.unsupported
        }
    }

    /// 人が確かめる段階の最終 PR
    private func reviewableFinal(_ epicID: Epic.ID) throws(ClientServiceError) -> (StateIndex.EpicEntry, StateIndex.FinalEntry) {
        let epic = try epic(epicID)
        guard let final = epic.final else {
            throw ClientServiceError(message: "最終 PR がまだありません")
        }
        guard final.isReviewable else {
            throw ClientServiceError(message: "いまは最終 PR を確かめられる段階ではありません。画面を取り直してから送ってください")
        }
        return (epic, final)
    }

    private func decisionTarget(
        _ decisionID: DecisionCard.ID,
        epic: StateIndex.EpicEntry,
        final: StateIndex.FinalEntry
    ) throws(ClientServiceError) -> DecisionTarget {
        guard final.decisionIDs.contains(decisionID) else {
            throw ClientServiceError(message: "この判断には、いまは答えられません（見える仮決めに仕分けられるのを待っています）")
        }
        guard let head = final.head else {
            throw ClientServiceError(message: "最終 PR の head が分かりません。取り直してから送ってください")
        }
        return DecisionTarget(repo: epic.repo, epic: epic.id, decision: decisionID, head: head)
    }

    private func finalTarget(_ epicID: Epic.ID, headCommit: String) throws(ClientServiceError) -> FinalPullRequestTarget {
        let (epic, _) = try reviewableFinal(epicID)
        guard AttemptFile.isCommitSHA(headCommit) else {
            throw ClientServiceError(message: "最終 PR の head の形が違います")
        }
        return FinalPullRequestTarget(repo: epic.repo, epic: epic.id, head: headCommit)
    }

    /// 別案・直してほしいの本文。何をどうしてほしいかが無いと直せないので、空は送らない
    private static func decisionNote(_ note: String) throws(ClientServiceError) -> String {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= DecisionIntent.maximumNoteLength else {
            throw ClientServiceError(message: "どうしてほしいかを 1〜\(DecisionIntent.maximumNoteLength) 文字で書いてください")
        }
        return text
    }

    private func epic(_ id: Epic.ID) throws(ClientServiceError) -> StateIndex.EpicEntry {
        guard let epic = index.epics[id] else {
            throw ClientServiceError(message: "この epic は、状態リポジトリにまだありません。取り直してから送ってください")
        }
        return epic
    }

    private func question(_ questionID: Question.ID, in epicID: Epic.ID) throws(ClientServiceError) -> QuestionTarget {
        let epic = try epic(epicID)
        guard epic.isActive else {
            throw ClientServiceError(message: "やめた epic の質問には答えられません")
        }
        guard let question = index.questions[epicID]?[questionID] else {
            throw ClientServiceError(message: "\(questionID) は、状態リポジトリにありません")
        }
        return QuestionTarget(repo: epic.repo, epic: epic.id, question: question.id, version: question.version)
    }

    /// 開始とゴールの修正の対象。確かめたゴールの版を付ける
    private func goal(of epicID: Epic.ID) throws(ClientServiceError) -> EpicTarget {
        let epic = try epic(epicID)
        guard let version = epic.goalVersion else {
            throw ClientServiceError(message: "ゴールがまだありません")
        }
        return EpicTarget(repo: epic.repo, epic: epic.id, version: version)
    }

    private func repository(_ id: TargetRepository.ID) throws(ClientServiceError) -> RepositoryFullName {
        guard let repo = index.repositories[id] else {
            throw ClientServiceError(message: "このリポジトリは、まだ対象に加わっていません")
        }
        return repo
    }
}
