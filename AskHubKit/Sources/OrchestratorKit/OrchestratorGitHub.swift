import AskHubKit
import Foundation

/// オーケストレーターが使う GitHub の操作。テストでは差し替える
public protocol OrchestratorGitHub: Sendable {
    /// organization 全体の、`ready-for-loop` が付いた open な Discussion
    func readyForLoopDiscussions(orgs: [String]) async throws -> [ReadyDiscussion]
    /// organization 全体の、`manual-loop` が付いた open な Discussion（手で回す epic）
    func manualLoopDiscussions(orgs: [String]) async throws -> [ManualLoopDiscussion]
    /// Discussion から `ready-for-loop` を外す
    func removeReadyLabel(from discussion: ReadyDiscussion) async throws
    /// org 全体の open な `epic-final` PR のうち、GitHub が既定ブランチとコンフリクトすると判定したもの
    func conflictingEpicFinalPullRequests(orgs: [String]) async throws -> [ConflictingPullRequest]
    /// org 全体の open な `epic-final` PR（信用する author が作ったもの）の、第三者レビューの対象を決めるための状態（Discussion #503）
    func finalReviewCandidates(orgs: [String], trust: TrustDirectory) async throws -> [FinalReviewCandidate]
    /// PR の会話にコメントし、コメントの id を返す（最終 PR の第三者レビューの状態コメント）
    func createComment(onPullRequest number: Int, in repository: String, body: String) async throws -> Int
    /// Issue・PR のコメントを書き換える
    func updateComment(in repository: String, id: Int, body: String) async throws
    /// PR にコメントする
    func comment(onPullRequest number: Int, in repository: String, body: String) async throws
    /// epic の最終 PR の材料（子 PR・仮決め一覧・実機確認）を GitHub から集める
    func epicMaterials(in repository: String, branch: String) async throws -> EpicMaterials
    /// `ready-for-loop` の Discussion にコメントする
    func comment(on discussion: ReadyDiscussion, body: String) async throws
    /// Discussion / PR から `needs-answer` を外す
    func removeNeedsAnswerLabel(from subject: InboxSubject) async throws
    /// Discussion に `ready-for-loop` を付ける（質問がすべて回答されたとき）。既に付いていても失敗しない
    func addReadyLabel(to subject: InboxSubject) async throws
    /// `branch` を head にした PR（閉じたものも含む）。無ければ `nil`
    func existingPullRequest(in repository: String, head branch: String) async throws -> ExistingPullRequest?
    /// `branch` から既定ブランチへの epic の最終 PR を作る。PR の番号を返す
    func createEpicFinalPullRequest(in repository: String, head branch: String, body: String) async throws -> Int
    /// PR に `epic-final` を付ける。既に付いていても失敗しない
    func addEpicFinalLabel(in repository: String, number: Int) async throws
    /// PR の本文を置き換える
    func updatePullRequestBody(in repository: String, number: Int, body: String) async throws
    /// organization 全体の、`idea-request` が付いた open な Issue
    func ideaRequests(orgs: [String]) async throws -> [IdeaRequestIssue]
    /// 依頼 Issue にコメントする
    func comment(on issue: IdeaRequestIssue, body: String) async throws
    /// 依頼 Issue をクローズする（完了として）
    func close(_ issue: IdeaRequestIssue) async throws
    /// organization 全体の、`repo-request` が付いた open な Issue（担当リポジトリの作成・削除の依頼）
    func repositoryRequests(orgs: [String]) async throws -> [RepositoryRequestIssue]
    /// 担当リポジトリのラベル `askhub-orchestrator` を消す（担当から外したとき）。無ければ何もしない
    func deleteHeartbeat(in repository: String) async throws
    /// 状態用の Issue を閉じる（担当から外したとき。アプリのステータスタブに行を残さない）
    func closeLoopStatusIssue(in repository: String, number: Int) async throws
    /// 担当リポジトリのラベル `askhub-orchestrator` の説明を書き換える。ラベルが無ければ作る
    func updateHeartbeat(in repository: String, description: String) async throws
    /// リポジトリの、`decision-log` が付いた open な Issue（仮決め一覧）
    func decisionLogs(in repository: String) async throws -> [DecisionLogIssue]
    /// Issue のコメント（古い順）
    func comments(in repository: String, issue number: Int) async throws -> [IssueComment]
    /// リポジトリの、`epic-final` が付いた open な PR（epic の最終 PR）
    func epicFinalPullRequests(in repository: String) async throws -> [EpicFinalPullRequest]
    /// 仮決め一覧にコメントする
    func comment(on issue: DecisionLogIssue, body: String) async throws
    /// 仮決め一覧をクローズする（完了として）
    func close(_ issue: DecisionLogIssue) async throws
    /// リポジトリの、`loop-status` が付いた Issue（閉じたものも含む）
    func loopStatusIssues(in repository: String) async throws -> [LoopStatusIssueRecord]
    /// 状態用の Issue を作る（ラベルが無ければ作る）。Issue の番号を返す
    func createLoopStatusIssue(in repository: String, body: String) async throws -> Int
    /// 状態用の Issue の本文を置き換える。閉じられていれば開き直す
    func updateLoopStatusIssue(in repository: String, number: Int, body: String) async throws
    /// 状態用の Issue のコメント（古い順。author を問わない）。ループ（Discussion）ごとの状態はコメントに書く
    func loopStatusComments(in repository: String, issue number: Int) async throws -> [LoopStatusComment]
    /// 状態用の Issue にコメントを足す。コメントの id を返す
    func createLoopStatusComment(in repository: String, issue number: Int, body: String) async throws -> Int
    /// 状態用の Issue のコメントの本文を置き換える
    func updateLoopStatusComment(in repository: String, id: Int, body: String) async throws
    /// 状態用の Issue のコメントを消す（終わったループのもの）。既に無ければ何もしない
    func deleteLoopStatusComment(in repository: String, id: Int) async throws
    /// リポジトリの、`build-hosts` が付いた Issue（閉じたものも含む）
    func buildHostsIssues(in repository: String) async throws -> [LoopStatusIssueRecord]
    /// ビルドの Mac の状態の Issue を作る（ラベルが無ければ作る）。Issue の番号を返す
    func createBuildHostsIssue(in repository: String, body: String) async throws -> Int
    /// ビルドの Mac の状態の Issue の本文を置き換える。閉じられていれば開き直す
    func updateBuildHostsIssue(in repository: String, number: Int, body: String) async throws
    /// 添付の目印の blob SHA で中身を取り、大きさと SHA を確かめて返す（`docs/protocol.md` の「添付ファイル」の「読み方」）
    func attachmentContent(_ marker: AttachmentMarker, in repository: String) async throws -> Data
    /// Discussion の本文の末尾に添付欄を足す。本文に既にある目印（同じパス）は足さない
    func appendAttachments(_ markers: [AttachmentMarker], toDiscussion number: Int, in repository: String) async throws
    /// 最近更新された、マージ済みの最終 PR（`epic-final`）
    func mergedEpicFinalPullRequests(in repository: String) async throws -> [MergedEpicFinalPullRequest]
    /// Discussion の本文・コメント・返信（書いた人つき。コメントはページングを最後まで追う）
    func discussionTexts(in repository: String, number: Int) async throws -> [AuthoredText]
    /// `base` 宛ての子 PR（open・closed とも）のレビューコメント（ask と返信。書いた人つき）
    func childPullRequestReviewComments(in repository: String, base branch: String) async throws -> [AuthoredText]
    /// `askhub/attachments` から `paths` を 1 つのコミットで消し、消した数を返す。ブランチやパスが無ければ 0。
    /// ref を更新できない（ブランチが先に進んだ）ときは `AttachmentCleanupError.conflict`
    func deleteAttachments(at paths: [String], in repository: String) async throws -> Int
}
