import AskHubProtocol
import Foundation

// MARK: - 人に渡されたジョブ

extension StateSnapshotBuilder {
    /// 人の対応を待っているジョブを、epic の「対処が要ります」に出す。処理を待つやり直し・やめるの意図を送ったジョブは飛ばす。
    ///
    /// 画面は epic ごとに 1 つだけ出すので、古く止まったものから出し、ほかにもあれば件数を添える（片付けると次のものが出る）
    func applyBlockers(to epics: inout [Epic], overlaid: [IntentEnvelope], index: inout StateIndex) {
        let handled = Set(overlaid.filter(Self.isJobIntent).compactMap { waitingJob(targetedBy: $0)?.id })
        for documents in documents.epics {
            let id = documents.epic.id.rawValue
            guard let epicIndex = epics.firstIndex(where: { $0.id == id }), epics[epicIndex].isActive else {
                continue
            }
            let waiting = documents.jobs
                .filter { $0.state == .waitingHuman && !handled.contains($0.id) }
                .sorted { ($0.updatedAt, $0.id.rawValue) < ($1.updatedAt, $1.id.rawValue) }
            guard let job = waiting.first else {
                continue
            }
            // 止まっている作業は、機械がしていることとして出さない（「対処が要ります」と食い違う）
            let stopped = Set(waiting.compactMap(Self.activity(of:)))
            epics[epicIndex].activities.removeAll { stopped.contains($0.kind) }
            let target = JobTarget(repo: job.repo, epic: job.epic, job: job.id, attempt: job.attempts)
            let blocker = blocker(
                job, target: target, stage: documents.epic.stage, attempts: documents.attempts[job.id] ?? [], others: waiting.count - 1
            )
            epics[epicIndex].blocker = blocker
            index.epics[id]?.blockedJob = target
            index.epics[id]?.blockerActions = Set(blocker.actions)
        }
    }

    /// ジョブが動いている間に「いま」に出る、機械がしていること
    private static func activity(of job: JobFile) -> EpicActivity.Kind? {
        let question = questionID(of: job)
        switch job.kind {
        case .makeQuestions:
            return .writingQuestions

        case .explain:
            return question.map(EpicActivity.Kind.explaining)

        case .reviseQuestion:
            return question.map(EpicActivity.Kind.reviewing)

        case .checkReadiness:
            return .checkingAnswers

        case .reviseGoal:
            return .revisingGoal

        default:
            return nil
        }
    }

    /// 画面の `Blocker.target`。ジョブと、人が見たときの試行の番号
    static func blockerTarget(_ target: JobTarget) -> String {
        "\(target.job.rawValue)/\(target.attempt)"
    }

    static func isJobIntent(_ envelope: IntentEnvelope) -> Bool {
        [RetryJobIntent.kind, GiveUpJobIntent.kind].contains(envelope.kind)
    }

    /// 意図の対象の、人の対応を待っているジョブ。人が見たときから試行が進んでいれば（司令塔が断る）nil
    func waitingJob(targetedBy envelope: IntentEnvelope) -> JobFile? {
        guard let job = job(targetedBy: envelope), job.state == .waitingHuman, envelope.targetVersion == String(job.attempts) else {
            return nil
        }
        return job
    }

    /// 意図の対象のジョブ。終わった epic のジョブは読まないので、見つからないことがある
    func job(targetedBy envelope: IntentEnvelope) -> JobFile? {
        guard let target = envelope.target, target.type == JobTarget.targetType, let epic = target.epic, let jobID = target.id else {
            return nil
        }
        return documents.epics.first { $0.epic.id == epic }?.jobs.first { $0.id.rawValue == jobID }
    }

    private func blocker(_ job: JobFile, target: JobTarget, stage: EpicStage, attempts: [AttemptFile], others: Int) -> Blocker {
        let failure = attempts.last { $0.number == job.attempts }?.failure
        let overLimit = failure == nil ? Self.fixOverLimit(job) : nil
        let category = failure?.failureClass.category ?? overLimit?.category ?? .unexpected
        let subject = subject(of: job)
        var summary = failure?.message ?? overLimit?.summary ?? "失敗の理由は書かれていません"
        if others > 0 {
            summary += "\nほかに \(others) 件の作業も対処を待っています（これを片付けると出ます）"
        }
        return Blocker(
            category: category,
            title: "\(subject)が止まっています",
            summary: summary,
            logExcerpt: failure?.logExcerpt,
            attempts: attempts.map(Self.attempt),
            occurredAt: job.updatedAt.date,
            actions: Self.actions(for: job.kind, at: stage, category: category),
            subject: subject,
            target: Self.blockerTarget(target)
        )
    }

    /// 直しの上限を超えて、試行の前に人に渡された直しの区分と理由（司令塔は、上限を超えた直しを動かさずに人の対応待ちで作る）。
    /// 区分は、直しの元になった失敗（CI・レビューの必須の指摘・コンフリクト）。ほかのジョブは nil
    private static func fixOverLimit(_ job: JobFile) -> (category: FailureCategory, summary: String)? {
        guard job.attempts == 0, [.fixTask, .fixFinalPullRequest].contains(job.kind) else {
            return nil
        }
        let remaining: (category: FailureCategory, text: String)? = switch job.input(as: FixTaskInput.self)?.reason {
        case .ci: (.build, "CI が通らないまま")
        case .review: (.review, "レビューの必須の指摘が残ったまま")
        case .conflict: (.conflict, "コンフリクトが残ったまま")
        // 人が頼んだ直しは上限で止めないので来ない
        case .human, nil: nil
        }
        let limit = "自動の直しが上限（\(FixTaskInput.maxAutomaticRounds) 回）を超えたので止めています。もう一度試すと、もう 1 回直します"
        return (remaining?.category ?? .unexpected, remaining.map { "\($0.text)、\(limit)" } ?? limit)
    }

    /// 選べる操作。司令塔が受け付けるものだけを出す（やり直しはどの種類でも、やめるは `JobKind.giveUpEffect(at:)` で扱いが決まっているものだけ）。
    /// 開始した後の epic に残っていた開始の前のジョブ（着手前の確認など）は、司令塔と同じく、epic ごとではなくその作業だけをやめる
    private static func actions(for kind: JobKind, at stage: EpicStage, category: FailureCategory) -> [Blocker.Action] {
        // 認証切れは、人が Mac で直してから再開する
        var actions: [Blocker.Action] = [category == .authExpired ? .resumeAfterFix : .retry]
        switch kind.giveUpEffect(at: stage) {
        case .abandonsEpic:
            actions.append(.discard)

        case .jobOnly:
            actions.append(.cancelJob)

        case nil:
            break
        }
        return actions
    }

    private static func attempt(_ file: AttemptFile) -> Blocker.Attempt {
        let outcome: String = if let failure = file.failure {
            "\(failure.failureClass.category.label): \(failure.message)"
        } else {
            switch file.outcome {
            case .succeeded: "終わりました"
            case .failed: "失敗しました"
            // 生きている印が途絶えた試行は、終わりを書かないまま止まっている
            case .running: "途中で止まりました"
            }
        }
        return Blocker.Attempt(
            number: file.number,
            macName: file.mac.rawValue,
            startedAt: file.startedAt.date,
            endedAt: (file.endedAt ?? file.heartbeatAt).date,
            outcome: outcome
        )
    }

    /// 止まっている作業の名前（例: Q3 の説明・タスク 2「並べ替えのボタン」の実装）
    func subject(of job: JobFile) -> String {
        if let taskID = job.task, let name = taskName(taskID, epic: job.epic) {
            switch job.kind {
            case .implementTask: return "\(name)の実装"
            case .reviewTask: return "\(name)の子 PR のレビュー"
            case .fixTask: return "\(name)の直し"
            default: break
            }
        }
        guard let question = Self.questionID(of: job) else {
            return job.kind.name
        }
        switch job.kind {
        case .explain:
            return "\(question) の説明"

        case .reviseQuestion:
            return "\(question) の見直し"

        default:
            return job.kind.name
        }
    }

    /// ゴールのタスクの呼び名（例: タスク 2「並べ替えのボタン」）。ゴールに無ければ nil
    func taskName(_ taskID: String, epic: ULID) -> String? {
        let tasks = documents.epics.first { $0.epic.id == epic }?.goal?.tasks ?? []
        guard let offset = tasks.firstIndex(where: { $0.id == taskID }) else {
            return nil
        }
        return "タスク \(offset + 1)「\(tasks[offset].title)」"
    }

    /// 質問を対象にするジョブ（説明・見直し）の、画面の質問の id
    static func questionID(of job: JobFile) -> Question.ID? {
        guard case .string(let id)? = job.input?["question"] else {
            return nil
        }
        return displayID(id)
    }
}

private extension JobKind {
    /// 作業の名前
    var name: String {
        switch self {
        case .makeQuestions: "質問づくり"
        case .explain: "質問の説明"
        case .reviseQuestion: "質問の見直し"
        case .checkReadiness: "着手前の確認"
        case .reviseGoal: "ゴールの修正"
        case .prepareWorkspace: "作業場所の準備"
        case .implementTask: "タスクの実装"
        case .reviewTask: "子 PR のレビュー"
        case .fixTask: "タスクの修正"
        case .integrateDevelop: "develop の取り込み"
        case .verifyBeforeFinal: "最終 PR の前の確かめ"
        case .reviewFinalPullRequest: "最終 PR のレビュー"
        case .openFinalPullRequest: "最終 PR づくり"
        case .fixFinalPullRequest: "最終 PR の修正"
        case .rerunChecks: "CI のやり直し"
        case .classifyDecisions: "判断の仕分け"
        case .captureScreenshots: "スクリーンショットの撮影"
        case .mergeFinalPullRequest: "最終 PR のマージ"
        case .cleanUp: "片付け"
        case .notify: "通知"
        }
    }
}

private extension FailureClass {
    /// 画面の失敗の区分
    var category: FailureCategory {
        switch self {
        case .runnerUnavailable: .runnerShortage
        case .flaky: .flaky
        case .buildFailed, .testFailed: .build
        case .reviewRequired: .review
        case .conflict: .conflict
        case .usageLimit: .usageLimit
        case .authExpired: .authExpired
        case .githubOutage: .githubOutage
        case .claudeOutage: .claudeOutage
        case .macOffline: .macOffline
        case .timeout: .timeout
        case .unexpected: .unexpected
        }
    }
}
