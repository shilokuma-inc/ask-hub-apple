import AskHubKit
import Foundation

/// 「新しい依頼」画面で送った依頼。表示は送った時点の値で組み立てる（送信後に Picker でリポジトリを変えても変わらない）
struct SentRequest: Equatable, Identifiable {
    /// 送った時点のリポジトリ（`owner/repo`）
    let repository: String
    /// 入力した要約。Issue タイトルの `【依頼】` は付けない
    let summary: String
    let issue: CreatedIssue
    /// 添付したファイルの数
    let attachmentCount: Int

    /// 送るたびに作る。同じ Issue の URL が返っても（サンプルの requester は毎回 #41 を返す）一覧の項目を区別できるようにする
    let id = UUID()

    init(request: IdeaRequest, issue: CreatedIssue) {
        repository = request.repository
        summary = request.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.issue = issue
        attachmentCount = request.attachments.count
    }

    /// 例: `ask-hub-apple に「通知の頻度を調整したい」を依頼しました`。添付があれば `（添付 2 件）` を添える
    var message: String {
        let attachments = attachmentCount > 0 ? "（添付 \(attachmentCount) 件）" : ""
        return "\(InboxSubject.shortRepository(repository)) に「\(summary)」を依頼しました\(attachments)"
    }

    /// 例: `ask-hub-apple#184 を GitHub で開く`（受信箱・マージ待ちと同じ `repo#番号` の表記）
    var linkTitle: String {
        "\(InboxSubject.shortRepository(repository))#\(issue.number) を GitHub で開く"
    }
}

/// 送った、担当リポジトリの作成・削除の依頼
struct SentRepositoryRequest: Equatable, Identifiable {
    let request: RepositoryRequest
    /// 依頼 Issue を作ったリポジトリ（`owner/repo`）
    let repository: String
    let issue: CreatedIssue
    let id = UUID()

    /// 例: `my-quiz-ios（iOS）の作成を依頼しました`
    var message: String {
        switch request {
        case let .create(newRepository):
            "\(InboxSubject.shortRepository(request.repository))（\(newRepository.platform.title)）の作成を依頼しました"

        case .remove:
            "\(InboxSubject.shortRepository(request.repository)) を担当から外す依頼をしました"

        case .add:
            "\(InboxSubject.shortRepository(request.repository)) を担当に入れる依頼をしました"
        }
    }

    var linkTitle: String {
        "\(InboxSubject.shortRepository(repository))#\(issue.number) を GitHub で開く"
    }
}
