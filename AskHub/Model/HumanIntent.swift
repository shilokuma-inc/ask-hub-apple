import Foundation

/// 人の意図。機械を動かす人の書き込みで、クライアントが署名して GitHub に書く（docs/renewal/security.md）。
///
/// 画面はこの値を作ってストアに渡すだけにし、署名や書き込みの方法は知らない
enum HumanIntent: Hashable {
    case answer(epicID: Epic.ID, questionID: Question.ID, optionID: Question.Option.ID?, note: String)
    case requestExplanation(epicID: Epic.ID, questionID: Question.ID, request: String)
    case reviseGoal(epicID: Epic.ID, request: String)
    case start(epicID: Epic.ID, macID: Mac.ID)
    /// 1 つの epic に収まらないと分かったときの、分け方の判断
    case decideSplit(epicID: Epic.ID, choice: SplitChoice)
    /// 判断のカードへの答えは、カードを見たときの最終 PR の head に結びつける（見た後に head が進んでいれば送らない）
    case respondToDecision(epicID: Epic.ID, decisionID: DecisionCard.ID, headCommit: String?, reply: DecisionReply)
    /// 並べて見て、残りの判断をまとめて OK にする。見たときの head と、画面に出していたカードに結びつける（見ていないカードは OK にしない）
    case acceptAllDecisions(epicID: Epic.ID, headCommit: String?, decisionIDs: [DecisionCard.ID])
    /// マージの承認は、その時点の head のコミットに結びつける
    case merge(epicID: Epic.ID, headCommit: String)
    /// 最終 PR への指示（Claude に直させ、最終 PR のレビューからやり直す）。見た head のコミットに結びつける
    case instructFinal(epicID: Epic.ID, headCommit: String, instruction: String)
    /// `target` は画面に出した `Blocker.target`。送るまでに対象が替わっていれば送らない
    case resolveBlocker(epicID: Epic.ID, action: Blocker.Action, instruction: String, target: String? = nil)
    case handOver(epicID: Epic.ID, macID: Mac.ID)
    case pause(epicID: Epic.ID)
    case resume(epicID: Epic.ID)
    case discard(epicID: Epic.ID)
    /// 人がする作業を終えた。ファイルを渡す作業は、渡すファイルを付ける（中身は意図より先に状態リポジトリに置く）。
    /// GitHub の Secrets に入れる作業は、人が GitHub の設定画面で入れてから終えたことにする（値は受け取らない）
    case completeHumanTask(epicID: Epic.ID, taskID: HumanTask.ID, file: HandoverFile? = nil)
    case verify(epicID: Epic.ID, itemID: VerificationItem.ID, reply: VerificationReply)
    case cleanUp(macID: Mac.ID, candidateIDs: [CleanupCandidate.ID])
    /// 依頼。添付の中身は、意図より先に状態リポジトリに置く
    case request(repositoryID: TargetRepository.ID, summary: String, body: String, attachments: [RequestFile] = [])
    case addRepository(repositoryID: TargetRepository.ID)
}

enum SplitChoice: Hashable {
    /// 今の epic をやめ、分け方の案ごとに依頼し直す
    case split
    /// このまま 1 つの epic で進める（着手前の確認をやり直して、ゴールを作る）
    case proceed
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

extension HumanIntent {
    var isRequest: Bool {
        if case .request = self {
            return true
        }
        return false
    }

    /// 送ったことを知らせるときの呼び名（状態リポジトリの「送った意図」と同じ呼び方。例: 依頼「週ごとのまとめ」・回答・開始）
    var label: String {
        switch self {
        case let .request(_, summary, _, _):
            "依頼「\(summary)」"

        case .answer:
            "回答"

        case .requestExplanation:
            "説明の依頼"

        case .reviseGoal:
            "ゴールの修正"

        case .start:
            "開始"

        case .decideSplit:
            "分け方の判断"

        case .addRepository(let repositoryID):
            "対象に加える（\(repositoryID)）"

        case let .resolveBlocker(_, action, _, _):
            Self.label(of: action)

        case .discard:
            "取り下げ"

        case .respondToDecision:
            "判断への回答"

        case .acceptAllDecisions:
            "まとめての OK"

        case .merge:
            "マージの承認"

        case .instructFinal:
            "最終 PR への指示"

        case .handOver:
            "引き継ぎ"

        case .pause:
            "一時停止"

        case .resume:
            "再開"

        case .completeHumanTask:
            "作業の完了"

        case .verify:
            "確かめた結果"

        case .cleanUp:
            "片付け"
        }
    }

    private static func label(of action: Blocker.Action) -> String {
        switch action {
        case .retry, .resumeAfterFix:
            "やり直し"

        case .cancelJob, .discard:
            "取りやめ"

        case .fixWithInstruction:
            "直す指示"

        case .handOver:
            "引き継ぎ"

        case .pause:
            "一時停止"
        }
    }
}
