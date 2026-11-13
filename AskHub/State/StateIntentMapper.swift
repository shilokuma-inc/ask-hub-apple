import AskHubClient
import AskHubProtocol
import Foundation

/// 画面の人の意図（`HumanIntent`）を、状態リポジトリに送る形（`IntentDraft`）に変える。
///
/// 対象の版（質問・ゴール・着手前の確認の結果）は、最後に読んだ状態（`StateIndex`）から取る。人が見たものの版で送るので、
/// その後に対象が変わっていれば、司令塔が古い意図として断る
struct StateIntentMapper {
    let index: StateIndex

    /// 状態リポジトリに送れる意図か。段階 3 の操作のうち、確認・片付けなどは、まだ送れない。
    /// 人に渡されたジョブへの操作は、最後に読んだ状態の「対処が要ります」に出した操作だけ（やり直す・やめる）、取り下げは開始する前の epic だけ、
    /// 最終 PR への操作（判断のカードへの答え・マージの承認・指示）は最終 PR を出した epic だけ、
    /// 人がする作業を終えたことは、ゴールの確認の待ちと実装の間の、終えていない作業だけ送れる。
    /// 一時停止・再開・引き継ぎは開始した後の epic だけで、引き継ぎは、一時停止していなければ epic の Mac でジョブが動いていないときだけ送れる。
    /// 実機確認への答えは、マージした epic の、まだ答えていない項目だけ送れる
    func supports(_ intent: HumanIntent) -> Bool {
        switch intent {
        case .answer, .requestExplanation, .reviseGoal, .start, .decideSplit, .request, .addRepository:
            true

        case let .resolveBlocker(epicID, action, _, _):
            index.epics[epicID]?.blockerActions.contains(action) == true

        case .discard(let epicID):
            index.epics[epicID]?.canAbandon == true

        case let .respondToDecision(epicID, _, _, _), let .acceptAllDecisions(epicID, _, _), let .merge(epicID, _),
             let .instructFinal(epicID, _, _):
            index.epics[epicID]?.final != nil

        case let .completeHumanTask(epicID, taskID, _):
            index.epics[epicID]?.humanTasks[taskID] != nil

        case .pause(let epicID):
            index.epics[epicID]?.canPause == true

        case .resume(let epicID):
            index.epics[epicID]?.canResume == true

        case let .handOver(epicID, _):
            index.epics[epicID]?.canHandOver == true

        case .publishRelease, .verify:
            supportsAfterMerge(intent)

        case .removeRepository, .configureRepository, .applyProtection, .approveSetup, .cleanUp:
            supportsRepositoryIntent(intent)
        }
    }

    /// 意図より先に状態リポジトリに置く中身（依頼の添付・渡すファイル）。`drafts(for:)` の payload の `attachments` の順
    static func attachments(for intent: HumanIntent) -> [Data] {
        switch intent {
        case let .request(_, _, _, files):
            files.map(\.data)

        case let .completeHumanTask(_, _, file?):
            [file.data]

        default:
            []
        }
    }

    /// 送る形。まとめて OK は、答えの無いカードそれぞれへの OK にする（司令塔は判断のカードへの答えを 1 枚ずつ受け取る）。
    /// 人が見ていなかった答え待ちのカードがあれば（見た後に足された）、どれも送らない
    func drafts(for intent: HumanIntent) throws(ClientServiceError) -> [IntentDraft] {
        if case let .verify(epicID, itemID, reply) = intent {
            return try verifyDrafts(epicID: epicID, itemID: itemID, reply: reply)
        }
        guard case let .acceptAllDecisions(epicID, headCommit, shownIDs) = intent else {
            return [try draft(for: intent)]
        }
        let (epic, final) = try reviewableFinal(epicID)
        guard final.unansweredDecisionIDs.allSatisfy(shownIDs.contains) else {
            throw Self.updated
        }
        guard !final.unansweredDecisionIDs.isEmpty else {
            throw ClientServiceError(message: "まとめて OK にする判断がありません")
        }
        return try final.unansweredDecisionIDs.map { id throws(ClientServiceError) in
            .decision(try decisionTarget(id, seenHead: headCommit, epic: epic, final: final), answer: .ok)
        }
    }

    private func draft(for intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case .answer, .requestExplanation:
            return try questionDraft(intent)

        case .reviseGoal, .start, .decideSplit, .discard:
            return try epicDraft(intent)

        case .request, .addRepository, .removeRepository, .configureRepository, .applyProtection, .approveSetup:
            return try repositoryDraft(intent)

        case let .resolveBlocker(epicID, action, _, target):
            return try blockerDraft(epicID: epicID, action: action, target: target)

        case .respondToDecision, .merge, .instructFinal:
            return try finalDraft(intent)

        case let .completeHumanTask(epicID, taskID, file):
            return try humanTaskDraft(epicID: epicID, taskID: taskID, file: file)

        case .pause, .resume, .handOver:
            return try pauseDraft(intent)

        case let .publishRelease(repositoryID, version, notesVersion, notes):
            return try releaseDraft(repositoryID: repositoryID, version: version, notesVersion: notesVersion, notes: notes)

        case .acceptAllDecisions, .verify, .cleanUp:
            // まとめて OK と実機確認は、いくつかの意図になることがあるので `drafts(for:)` で作る
            throw Self.unsupported
        }
    }

    static let unsupported = ClientServiceError(message: "この操作は、まだ状態リポジトリに送れません")
    /// 人が見た後に最終 PR が変わった（head が進んだ・答え待ちのカードが増えた）。見ていない状態に答えを結びつけないよう、送らない
    private static let updated = ClientServiceError(message: "最終 PR が更新されました。見直してから答えてください")

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

    /// 一時停止・再開・引き継ぎ。どれも epic の今の状態に対してだけ意味を持つので、版を付けない
    private func pauseDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case .pause(let epicID):
            let epic = try epic(epicID)
            guard epic.canPause else {
                throw ClientServiceError(message: "いまは一時停止できません（開始した後で、止めていない epic だけです）")
            }
            return .pauseEpic(repo: epic.repo, epic: epic.id)

        case .resume(let epicID):
            let epic = try epic(epicID)
            guard epic.canResume else {
                throw ClientServiceError(message: "この epic は一時停止していません")
            }
            return .resumeEpic(repo: epic.repo, epic: epic.id)

        case let .handOver(epicID, macID):
            let epic = try epic(epicID)
            guard epic.canHandOver else {
                throw ClientServiceError(message: "Mac で動いている作業があります。一時停止してから引き継いでください")
            }
            guard let mac = MacName(rawValue: macID) else {
                throw ClientServiceError(message: "Mac の名前の形が違います")
            }
            guard mac != epic.mac else {
                throw ClientServiceError(message: "いま回している Mac です。ほかの Mac を選んでください")
            }
            return .handover(repo: epic.repo, epic: epic.id, to: mac)

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
        case let .respondToDecision(epicID, decisionID, headCommit, reply):
            let (epic, final) = try reviewableFinal(epicID)
            let target = try decisionTarget(decisionID, seenHead: headCommit, epic: epic, final: final)
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
            // 司令塔（`PayloadReader`）と同じく、Unicode のコードポイントで数える（結合文字を含む文は、見た目の文字数より多くなる）
            guard !text.isEmpty, text.unicodeScalars.count <= InstructFinalIntent.maximumInstructionLength else {
                throw ClientServiceError(message: "指示は 1〜\(InstructFinalIntent.maximumInstructionLength) 文字で書いてください")
            }
            return .instructFinal(try finalTarget(epicID, headCommit: headCommit), instruction: text)

        default:
            throw Self.unsupported
        }
    }

    /// 人がする作業を終えた。確かめたゴールの版に結びつける（その後にゴールが直されていれば、司令塔が断る）。
    /// ファイルを渡す作業はファイルが 1 つ要り、ほかの作業（Secrets に入れる作業を含む）はファイルを付けない
    private func humanTaskDraft(epicID: Epic.ID, taskID: HumanTask.ID, file: HandoverFile?) throws(ClientServiceError) -> IntentDraft {
        let epic = try epic(epicID)
        guard let handover = epic.humanTasks[taskID], let version = epic.goalVersion else {
            throw ClientServiceError(message: "この作業は、いまは終えたことにできません。取り直してから送ってください")
        }
        let target = HumanTaskTarget(repo: epic.repo, epic: epic.id, task: taskID, goalVersion: version)
        switch (handover, file) {
        case (.file, let file?):
            return .humanTaskDone(target, file: file.attachment)

        case (.file, nil):
            throw ClientServiceError(message: "渡すファイルを選んでください")

        case (.none, nil), (.secret, nil):
            return .humanTaskDone(target)

        case (.none, _?), (.secret, _?):
            throw ClientServiceError(message: "この作業では、ファイルを渡しません")
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

    /// 判断のカードへの答えの対象。人がカードを見たときの head に結びつける（見た後に head が進んでいれば送らない）
    private func decisionTarget(
        _ decisionID: DecisionCard.ID,
        seenHead: String?,
        epic: StateIndex.EpicEntry,
        final: StateIndex.FinalEntry
    ) throws(ClientServiceError) -> DecisionTarget {
        guard final.decisionIDs.contains(decisionID) else {
            throw ClientServiceError(message: "この判断には、いまは答えられません（見える仮決めに仕分けられるのを待っています）")
        }
        guard let head = final.head else {
            throw ClientServiceError(message: "最終 PR の head が分かりません。取り直してから送ってください")
        }
        guard seenHead == head else {
            throw Self.updated
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
        // 司令塔（`PayloadReader`）と同じく、Unicode のコードポイントで数える
        guard !text.isEmpty, text.unicodeScalars.count <= DecisionIntent.maximumNoteLength else {
            throw ClientServiceError(message: "どうしてほしいかを 1〜\(DecisionIntent.maximumNoteLength) 文字で書いてください")
        }
        return text
    }

    func epic(_ id: Epic.ID) throws(ClientServiceError) -> StateIndex.EpicEntry {
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

    func repository(_ id: TargetRepository.ID) throws(ClientServiceError) -> RepositoryFullName {
        guard let repo = index.repositories[id] else {
            throw ClientServiceError(message: "このリポジトリは、まだ対象に加わっていません")
        }
        return repo
    }
}

// MARK: - App Store で配信した版

extension StateIntentMapper {
    /// 配信した版のリリース文を公開する。人が見た下書きの版に結びつける（その後に下書きが作り直されていれば、司令塔が断る）
    func releaseDraft(
        repositoryID: TargetRepository.ID,
        version: String,
        notesVersion: Int,
        notes: String
    ) throws(ClientServiceError) -> IntentDraft {
        guard let entry = index.releases[Release.id(repositoryID, version)], entry.canPublish else {
            throw ClientServiceError(message: "この版のリリース文は、いまは公開できません。取り直してから送ってください")
        }
        guard entry.target.notesVersion == notesVersion else {
            throw ClientServiceError(message: "リリース文の下書きが作り直されました。見直してから公開してください")
        }
        // 司令塔（`PayloadReader`）と同じく、Unicode のコードポイントで数える
        let text = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.unicodeScalars.count <= PublishGitHubReleaseIntent.notesLimit else {
            throw ClientServiceError(message: "リリース文は 1〜\(PublishGitHubReleaseIntent.notesLimit) 文字で書いてください")
        }
        return .publishGitHubRelease(entry.target, notes: text)
    }
}
