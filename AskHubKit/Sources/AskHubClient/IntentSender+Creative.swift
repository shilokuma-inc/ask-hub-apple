import AskHubProtocol
import Foundation

// クリエイティブアセット（App Store のヘッダー・検索結果の画像）の意図の送る形（`docs/renewal/creative-assets.md`）

extension IntentDraft {
    /// クリエイティブアセットの案を頼む・直してほしいことを書く（人が見た案の版に結びつける。案が無ければ 0）
    public static func draftCreativeAssets(_ repo: RepositoryFullName, revision: Int, comment: String?) -> Self {
        Self(
            kind: DraftCreativeAssetsIntent.kind,
            repo: repo,
            target: .init(type: CreativeIntents.targetType),
            targetVersion: String(revision),
            payload: DraftCreativeAssetsIntent.payload(comment: comment)
        )
    }

    /// 書き出したクリエイティブアセットの案を承認する（人が見た案の版に結びつける）
    public static func approveCreativeAssets(_ repo: RepositoryFullName, revision: Int) -> Self {
        Self(
            kind: ApproveCreativeAssetsIntent.kind,
            repo: repo,
            target: .init(type: CreativeIntents.targetType),
            targetVersion: String(revision)
        )
    }
}
