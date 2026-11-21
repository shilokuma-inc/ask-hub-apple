import AskHubProtocol
import Foundation

// リリースを始めた版の掲載文と App Review の情報の案の材料（`ReleaseWatch+Submissions.swift` の `draftListing` が使う）

extension ReleaseWatch {
    /// 今の掲載文。配信中の版ならその文、初めての版なら編集できる版のすべてにそろっている欄だけ
    func currentListing(
        _ sources: [AppStoreVersionInfo],
        firstVersion: Bool,
        store: any AppStoreConnectSubmitting
    ) async throws -> [ListingText] {
        var listings: [[ListingText]] = []
        for source in sources {
            let localizations = try await appStoreConnect { () throws(AppStoreConnectError) in
                try await store.localizations(of: source.id)
            }
            listings.append(localizations.map(\.listing))
        }
        return firstVersion ? Self.commonListing(listings) : listings.first ?? []
    }

    /// 配信中の版の App Review の情報（パスワードと連絡先は読まない）。初めての版は案を書かない（App Store の準備のチェックリストで扱う）
    func reviewDetail(of live: AppStoreVersionInfo?, store: any AppStoreConnectSubmitting) async throws -> AppStoreReviewDetail? {
        guard let live else { return nil }
        return try await appStoreConnect { () throws(AppStoreConnectError) in try await store.reviewDetail(of: live.id) }
    }

    /// App Review の情報の案（理由が無ければ、変えないとする決まった文）
    func appReview(_ proposal: ListingProposal, current: AppStoreReviewDetail?) -> SubmissionFile.AppReview {
        .init(
            current: current?.information ?? ReviewInformation(),
            draft: proposal.review,
            reason: proposal.reviewReason.flatMap { $0.isEmpty ? nil : $0 } ?? "審査する人に伝えることは変わらないので、変えません",
            draftedAt: context.timestamp
        )
    }
}
