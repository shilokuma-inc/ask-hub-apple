import Foundation

/// 人の意図が働きかける画面の要素（カード・行・ボタン）。
///
/// 送った意図が画面に反映されるまで、同じ対象への操作を止めて、その場に「反映中」を出すのに使う（`ReflectionTracker`）。
/// 画面の意図からはここの `HumanIntent.targets` が、状態リポジトリの送った意図からは `StateSnapshotBuilder.target(of:)` が、同じ対象を決める。
/// 送った控え（`SendReceipt`）が持つので、nonisolated にする
nonisolated enum IntentTarget: Hashable {
    /// 質問（回答・説明の依頼）
    case question(epicID: Epic.ID, questionID: Question.ID)
    /// ゴール（開始・ゴールの修正）
    case goal(epicID: Epic.ID)
    /// 1 つの epic に収まらないときの分け方の判断
    case split(epicID: Epic.ID)
    /// 判断のカード（答え・まとめての OK）
    case decision(epicID: Epic.ID, decisionID: DecisionCard.ID)
    /// 最終 PR（マージの承認・最終 PR への指示）
    case finalPullRequest(epicID: Epic.ID)
    /// 「対処が要ります」に出した作業（やり直す・やめる）
    case blocker(epicID: Epic.ID)
    /// epic の操作（一時停止・再開・引き継ぎ・取り下げ）
    case epicControl(epicID: Epic.ID)
    case humanTask(epicID: Epic.ID, taskID: HumanTask.ID)
    case verification(epicID: Epic.ID, itemID: VerificationItem.ID)
    /// 依頼から作られる epic（送り終えて id が分かってから）
    case request(epicID: Epic.ID)
    /// 対象に加えるリポジトリ
    case repository(TargetRepository.ID)
    /// Mac の片付け
    case cleanup(macID: Mac.ID)
    /// App Store で配信した版（リリース文の公開）
    case release(repositoryID: TargetRepository.ID, version: String)

    /// 対象の epic。epic に属さない対象（リポジトリ・Mac）は nil
    var epicID: Epic.ID? {
        switch self {
        case let .question(epicID, _), let .goal(epicID), let .split(epicID), let .decision(epicID, _), let .finalPullRequest(epicID),
             let .blocker(epicID), let .epicControl(epicID), let .humanTask(epicID, _), let .verification(epicID, _), let .request(epicID):
            epicID

        case .repository, .cleanup, .release:
            nil
        }
    }
}

extension HumanIntent {
    /// 意図が働きかける対象。まとめて OK は、OK にするカードそれぞれ。依頼は、送り終えて epic の id が分かるまで対象を持たない
    var targets: [IntentTarget] {
        switch self {
        case let .answer(epicID, questionID, _, _), let .requestExplanation(epicID, questionID, _):
            [.question(epicID: epicID, questionID: questionID)]

        case let .reviseGoal(epicID, _), let .start(epicID, _):
            [.goal(epicID: epicID)]

        case let .decideSplit(epicID, _):
            [.split(epicID: epicID)]

        case let .respondToDecision(epicID, decisionID, _, _):
            [.decision(epicID: epicID, decisionID: decisionID)]

        case let .acceptAllDecisions(epicID, _, decisionIDs):
            decisionIDs.map { .decision(epicID: epicID, decisionID: $0) }

        case let .merge(epicID, _), let .instructFinal(epicID, _, _):
            [.finalPullRequest(epicID: epicID)]

        case let .resolveBlocker(epicID, _, _, _):
            [.blocker(epicID: epicID)]

        case let .handOver(epicID, _), let .pause(epicID), let .resume(epicID), let .discard(epicID):
            [.epicControl(epicID: epicID)]

        case let .completeHumanTask(epicID, taskID, _):
            [.humanTask(epicID: epicID, taskID: taskID)]

        case let .verify(epicID, itemID, _):
            [.verification(epicID: epicID, itemID: itemID)]

        case let .cleanUp(macID, _):
            [.cleanup(macID: macID)]

        case .addRepository(let repositoryID), .removeRepository(let repositoryID), .configureRepository(let repositoryID, _):
            [.repository(repositoryID)]

        case let .publishRelease(repositoryID, version, _, _):
            [.release(repositoryID: repositoryID, version: version)]

        case .request:
            []
        }
    }
}

extension DeckCard {
    /// カードで答える対象（答えを送ったら、反映されるまで山札から外す）
    var target: IntentTarget {
        switch content {
        case .question(let question):
            .question(epicID: epicID, questionID: question.id)

        case .decision(let decision):
            .decision(epicID: epicID, decisionID: decision.id)

        case .verification(let item):
            .verification(epicID: epicID, itemID: item.id)
        }
    }
}
