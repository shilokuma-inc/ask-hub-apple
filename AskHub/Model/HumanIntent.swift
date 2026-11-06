import Foundation

/// 人の意図。機械を動かす人の書き込みで、クライアントが署名して GitHub に書く（docs/renewal/security.md）。
///
/// 画面はこの値を作ってストアに渡すだけにし、署名や書き込みの方法は知らない
enum HumanIntent: Hashable {
    case answer(epicID: Epic.ID, questionID: Question.ID, optionID: Question.Option.ID?, note: String)
    case requestExplanation(epicID: Epic.ID, questionID: Question.ID, request: String)
    case reviseGoal(epicID: Epic.ID, request: String)
    case start(epicID: Epic.ID, macID: Mac.ID)
    case respondToDecision(epicID: Epic.ID, decisionID: DecisionCard.ID, reply: DecisionReply)
    /// 並べて見て、残りの判断をまとめて OK にする
    case acceptAllDecisions(epicID: Epic.ID)
    /// マージの承認は、その時点の head のコミットに結びつける
    case merge(epicID: Epic.ID, headCommit: String)
    case resolveBlocker(epicID: Epic.ID, action: Blocker.Action, instruction: String)
    case handOver(epicID: Epic.ID, macID: Mac.ID)
    case pause(epicID: Epic.ID)
    case resume(epicID: Epic.ID)
    case discard(epicID: Epic.ID)
    case completeHumanTask(epicID: Epic.ID, taskID: HumanTask.ID)
    /// 秘密の値は意図に含めない（クライアントが GitHub の Secrets に直接入れ、入れたことだけを知らせる）
    case submitSecret(epicID: Epic.ID, taskID: HumanTask.ID)
    case verify(epicID: Epic.ID, itemID: VerificationItem.ID, reply: VerificationReply)
    case cleanUp(macID: Mac.ID, candidateIDs: [CleanupCandidate.ID])
    case request(repositoryID: TargetRepository.ID, summary: String, body: String)
    case addRepository(repositoryID: TargetRepository.ID)
}

enum DecisionReply: Hashable {
    case accept
    case alternative(String)
    case fix(String)
}

enum VerificationReply: Hashable {
    case confirmed
    case problem(note: String)
}
