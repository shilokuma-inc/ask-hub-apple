import AskHubProtocol
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
    /// 止まっているタスクを飛ばす（「対処が要ります」の `Blocker.Action.skipTask`）。`target` は画面に出した `Blocker.target`
    case skipTask(epicID: Epic.ID, reason: TaskSkip, note: String, target: String? = nil)
    case handOver(epicID: Epic.ID, macID: Mac.ID)
    case pause(epicID: Epic.ID)
    case resume(epicID: Epic.ID)
    case discard(epicID: Epic.ID)
    /// 人がする作業を終えた。ファイルを渡す作業は、渡すファイルを付ける（中身は意図より先に状態リポジトリに置く）。
    /// GitHub の Secrets に入れる作業は、人が GitHub の設定画面で入れてから終えたことにする（値は受け取らない）
    case completeHumanTask(epicID: Epic.ID, taskID: HumanTask.ID, file: HandoverFile? = nil)
    /// GitHub の Secrets に入れる作業を、値を渡して終える。値はこの端末でリポジトリの公開鍵で暗号化し、暗号文だけを持つ（司令塔が Secrets に入れる）
    case handOverSecret(epicID: Epic.ID, taskID: HumanTask.ID, secret: EncryptedSecret)
    /// リポジトリの Secrets の公開鍵を、司令塔に読ませる（管理用のトークンで読む）
    case readSecretsKey(repositoryID: TargetRepository.ID)
    case verify(epicID: Epic.ID, itemID: VerificationItem.ID, reply: VerificationReply)
    /// 選んだ片付けの候補を消す（clone と DerivedData はゴミ箱に移し、Simulator は消す）
    case cleanUp(macID: Mac.ID, candidateIDs: [CleanupCandidate.ID])
    /// Mac の片付けの候補を探す（その Mac のワーカーが探す）
    case findCleanupCandidates(macID: Mac.ID)
    // 依頼の意図（`request`）の payload と同じ並びにしておくため、値を 5 つ持たせる（別の case にすると、依頼の扱いを 2 つに分けることになる）
    // swiftlint:disable enum_case_associated_values_count
    /// 依頼。添付の中身は、意図より先に状態リポジトリに置く。`release` は「このリリースを直す」依頼の直すリリースの版
    /// （epic は `release/<版>` を base にする）。ふだんの依頼は nil
    case request(repositoryID: TargetRepository.ID, summary: String, body: String, attachments: [RequestFile] = [], release: String? = nil)
    // swiftlint:enable enum_case_associated_values_count
    case addRepository(repositoryID: TargetRepository.ID)
    /// テンプレートから新しいアプリのリポジトリを作り、対象に加える（司令塔が管理用のトークンで作る）
    case createRepository(NewAppRequest)
    /// 配信した版のリリース文を確かめて、GitHub Release を公開する。見た下書きの版に結びつける（見た後に下書きが作り直されていれば、司令塔が断る）
    case publishRelease(repositoryID: TargetRepository.ID, version: String, notesVersion: Int, notes: String)
    /// 配信中の版のプロモーションテキストを直して、すぐ反映する（変える言語だけ。空の文は空にする）
    case updatePromotionalText(repositoryID: TargetRepository.ID, version: String, texts: [Submission.Localized])
    /// リリースを始める（`version` は始める版）
    case startRelease(repositoryID: TargetRepository.ID, version: String)
    /// 審査に出す（`revision` は見たときの準備の版。ビルドか What's New が変わっていれば司令塔が断る）
    case submitForReview(repositoryID: TargetRepository.ID, version: String, request: Submission.SubmitRequest)
    /// 審査に通った版を配信する（取り消せない）
    case distributeRelease(repositoryID: TargetRepository.ID, version: String)
    /// 審査を取り下げる
    case withdrawSubmission(repositoryID: TargetRepository.ID, version: String)
    /// このリリースをやめる
    case abandonRelease(repositoryID: TargetRepository.ID, version: String)
    /// スクショを撮り直す（`displayTypes`・`locales` が空なら、すべての組）
    case retakeScreenshots(repositoryID: TargetRepository.ID, version: String, displayTypes: [String], locales: [String])
    /// 対象から外す（終わっていない epic があれば司令塔が断る。状態リポジトリのファイルと GitHub のリポジトリは消さない）
    case removeRepository(repositoryID: TargetRepository.ID)
    /// ビルドの設定を入れる（`json` は `repo.json` の `build` と同じ形。送るたびにまるごと置き換える）
    case configureRepository(repositoryID: TargetRepository.ID, json: String)
    /// 保護の設定（司令塔が管理用のトークンでルールセットを掛ける）。必須のチェックは人が確かめて直したもの
    case applyProtection(repositoryID: TargetRepository.ID, requiredChecks: [String])
    /// 加えるときに司令塔が出したワークフローの直しの PR のマージの承認。見たときの head に結びつける
    case approveSetup(repositoryID: TargetRepository.ID, pullRequest: Int, head: String)
    /// Bundle ID を登録する（司令塔が App Store Connect に送る）
    case registerBundleId(repositoryID: TargetRepository.ID, identifier: String, platform: AppStoreSetup.BundlePlatform)
    /// 決まった値（価格・配信の地域・カテゴリ・コンテンツの権利・プライバシーポリシーの URL）を App Store Connect に書く
    case applyAppStoreSettings(repositoryID: TargetRepository.ID, request: AppStoreSettingsRequest)
    /// App Store Connect の Web でした作業を「終わった」にする
    case confirmAppStoreItem(repositoryID: TargetRepository.ID, item: AppStoreSetup.ItemKind)
    /// App Store に出さない（`excluded` が false なら出すに戻す）
    case excludeFromAppStore(repositoryID: TargetRepository.ID, excluded: Bool)
}

/// タスクを飛ばす理由
enum TaskSkip: Hashable, CaseIterable {
    /// 人が別にやる（別のリポジトリの PR など）
    case handledElsewhere
    /// やらない
    case notNeeded

    var label: String {
        switch self {
        case .handledElsewhere: "人が別にやる"
        case .notNeeded: "やらない"
        }
    }
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
    /// 問題あり。`release` があれば「このリリースで直す」（直しの依頼をその版の release ブランチに向ける）、nil なら次のリリースで直す
    case problem(note: String, release: String? = nil)
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
        case let .request(_, summary, _, _, _):
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

        case .createRepository(let request):
            "新しいアプリ（\(request.fullName)）"

        case let .publishRelease(_, version, _, _):
            "GitHub Release の公開（\(version)）"

        case let .updatePromotionalText(_, version, _):
            "プロモーションテキストの反映（\(version)）"

        case let .startRelease(_, version):
            "リリースを始める（\(version)）"

        case let .submitForReview(_, version, _):
            "審査に出す（\(version)）"

        case let .distributeRelease(_, version):
            "配信する（\(version)）"

        case let .withdrawSubmission(_, version):
            "審査の取り下げ（\(version)）"

        case let .abandonRelease(_, version):
            "リリースをやめる（\(version)）"

        case let .retakeScreenshots(_, version, _, _):
            "スクショの撮り直し（\(version)）"

        case .removeRepository(let repositoryID):
            "対象から外す（\(repositoryID)）"

        case .configureRepository(let repositoryID, _):
            "ビルドの設定（\(repositoryID)）"

        case .applyProtection:
            "保護の設定"

        case .approveSetup:
            "ワークフローの直しの承認"

        case let .registerBundleId(_, identifier, _):
            "Bundle ID の登録（\(identifier)）"

        case .applyAppStoreSettings:
            "App Store Connect に値を書く"

        case let .confirmAppStoreItem(_, item):
            "終わった（\(item.title)）"

        case let .excludeFromAppStore(_, excluded):
            excluded ? "App Store に出さない" : "App Store に出すに戻す"

        case let .resolveBlocker(_, action, _, _):
            Self.label(of: action)

        case .skipTask:
            "タスクを飛ばす頼み"

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

        case .handOverSecret:
            "Secrets の値"

        case .readSecretsKey(let repositoryID):
            "Secrets の公開鍵を読む（\(repositoryID)）"

        case .verify:
            "確かめた結果"

        case .cleanUp:
            "片付け"

        case .findCleanupCandidates:
            "片付けの候補を探す頼み"
        }
    }

    private static func label(of action: Blocker.Action) -> String {
        switch action {
        case .retry, .resumeAfterFix:
            "やり直し"

        case .cancelJob, .discard:
            "取りやめ"

        case .skipTask:
            "タスクを飛ばす頼み"

        case .fixWithInstruction:
            "直す指示"

        case .handOver:
            "引き継ぎ"

        case .pause:
            "一時停止"
        }
    }
}
