import AskHubClient
import AskHubProtocol
import Foundation

// MARK: - クリエイティブアセット（App Store のヘッダー・検索結果の画像）

extension StateIntentMapper {
    /// 頼めるのは、対象のリポジトリで、人が見た案の版が今の案のままで、作っている途中でないとき。
    /// 承認できるのは、人が見た案が今の案で、書き出し終えて、まだ承認していないとき
    func supportsCreativeIntent(_ intent: HumanIntent) -> Bool {
        switch intent {
        case let .draftCreativeAssets(repositoryID, revision, comment):
            guard index.repositories[repositoryID] != nil else { return false }
            if let comment, comment.isEmpty || comment.unicodeScalars.count > CreativeIntents.commentLimit { return false }
            let entry = index.creatives[repositoryID]
            return (entry?.revision ?? 0) == revision && entry?.isWorking != true

        case let .approveCreativeAssets(repositoryID, revision):
            guard let entry = index.creatives[repositoryID] else { return false }
            return entry.revision == revision && entry.awaitsReview

        default:
            return false
        }
    }

    func creativeDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        guard supportsCreativeIntent(intent) else {
            throw ClientServiceError(message: "ヘッダーと検索結果の案が変わりました。読み直してから押してください")
        }
        switch intent {
        case let .draftCreativeAssets(repositoryID, revision, comment):
            return .draftCreativeAssets(try repository(repositoryID), revision: revision, comment: comment)

        case let .approveCreativeAssets(repositoryID, revision):
            return .approveCreativeAssets(try repository(repositoryID), revision: revision)

        default:
            throw Self.unsupported
        }
    }
}
