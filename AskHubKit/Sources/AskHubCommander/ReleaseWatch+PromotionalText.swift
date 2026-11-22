import AskHubProtocol
import AskHubStateStore
import Foundation

/// 配信中の版のプロモーションテキスト（審査に出さずに変えられる。`docs/renewal/release.md` の「掲載文」）。
/// 配信を見つける見回り（30 分ごと）で今の文を読んで配信の記録に書き、人が直した（`updatePromotionalText`）中身を App Store Connect に書く
extension ReleaseWatch {
    /// 配信中の版の今のプロモーションテキストを読み、変わっていれば配信の記録に書く（iOS の版を先に見る。言語はプラットフォームごとにあるが、ふつうは同じ）。
    /// App Store Connect の言語の並びは毎回同じではないので、言語の順に並べて比べ、その順で書く
    func readPromotionalText(
        _ repo: RepositoryFullName,
        versions: [AppStoreVersionInfo],
        store: any AppStoreConnectSubmitting
    ) async throws {
        guard let live = Self.liveVersion(versions), let version = live.version else { return }
        let localizations = try await store.localizations(of: live.id)
        guard !localizations.isEmpty else { return }
        let current = Self.byLocale(localizations.map { LocalizedText(locale: $0.locale, text: $0.listing.promotionalText ?? "") })
        let now = context.timestamp
        try await savePromotionalText(repo, version: version) { file in
            // 前の記録が別の順でも、並べ直しだけでは書き直さない
            guard file.promotionalText.map({ Self.byLocale($0.current) }) != current else { return false }
            if file.promotionalText == nil {
                file.promotionalText = .init(current: current, readAt: now)
            } else {
                file.promotionalText?.current = current
                file.promotionalText?.readAt = now
            }
            return true
        }
    }

    /// 人が直したプロモーションテキストを、配信中の版（プラットフォームごと）に書く。配信中の版（記録のうち最も新しい版）の、まだ書いていない中身だけ
    func applyPromotionalText(_ repo: RepositoryFullName, settings: RepositoryFile) async {
        guard !stores.isEmpty, let version = try? await StartReleaseHandler.releasedVersions(of: repo, in: context).max(),
              let file = try? await context.readable(ReleaseFile.self, at: StatePath.release(repo, version)),
              let request = file.promotionalText?.request, request.isPending else { return }
        do {
            let (store, app) = try await submissionApp(repo, settings: settings)
            let versions = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
            let targets = versions.filter { $0.state == .readyForDistribution && $0.versionString == version.rawValue }
            guard !targets.isEmpty else {
                throw ReleaseStepProblem("App Store Connect に配信中の \(version) の版が無い", needsHuman: true)
            }
            for target in targets { try await write(request.texts, to: target, store: store) }
            log("\(repo) の \(version) のプロモーションテキスト（\(request.texts.map(\.locale).joined(separator: "・"))）を App Store Connect に書いた")
            try await finish(request, repo: repo, version: version, failure: nil)
        } catch let problem as ReleaseStepProblem where problem.needsHuman {
            report("\(repo) の \(version) のプロモーションテキストを書けない: \(problem.message)")
            try? await finish(request, repo: repo, version: version, failure: problem.message)
        } catch {
            report("\(repo) の \(version) のプロモーションテキストを書けない（\(error)）。次の見回りでやり直す")
        }
    }

    /// 1 つのプラットフォームの版に書く（今の文と同じ言語は書かない）
    private func write(_ texts: [LocalizedText], to target: AppStoreVersionInfo, store: any AppStoreConnectSubmitting) async throws {
        let localizations = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.localizations(of: target.id) }
        for text in texts {
            guard let localization = localizations.first(where: { $0.locale == text.locale }) else {
                let message = "\(target.platform.rawValue) の版に \(text.locale) の掲載文が無い。App Store Connect で言語を確かめる"
                throw ReleaseStepProblem(message, needsHuman: true)
            }
            guard (localization.listing.promotionalText ?? "") != text.text else { continue }
            let change = ListingText(locale: text.locale, promotionalText: text.text)
            try await appStoreConnect { () throws(AppStoreConnectError) in try await store.updateListing(localization.id, change) }
        }
    }

    /// 書き終えた（`failure` が nil）・断られたことを記録に書く。書き終えたら、今の文にも写す。記録を読んだ後に人がほかの中身を押していれば書かない
    private func finish(
        _ request: ReleaseFile.PromotionalTextRequest,
        repo: RepositoryFullName,
        version: MarketingVersion,
        failure: String?
    ) async throws {
        let now = context.timestamp
        try await savePromotionalText(repo, version: version) { file in
            guard var promotionalText = file.promotionalText, promotionalText.request == request else { return false }
            if let failure {
                promotionalText.request?.failure = failure
            } else {
                promotionalText.request?.doneAt = now
                for text in request.texts {
                    if let index = promotionalText.current.firstIndex(where: { $0.locale == text.locale }) {
                        promotionalText.current[index].text = text.text
                    }
                }
                promotionalText.readAt = now
            }
            file.promotionalText = promotionalText
            return true
        }
    }

    nonisolated private func savePromotionalText(
        _ repo: RepositoryFullName,
        version: MarketingVersion,
        change: @escaping @Sendable (inout ReleaseFile) -> Bool
    ) async throws(CommanderError) {
        let path = StatePath.release(repo, version)
        let message = "\(repo) の \(version) のプロモーションテキスト"
        try await context.writingResult { () throws(CommanderError) in
            do throws(StateFileStore.Failure) {
                guard try await context.files.read(ReleaseFile.self, at: path) != nil else { return }
                try await context.files.update(ReleaseFile.self, at: path, message: message) { file in
                    guard change(&file) else { return false }
                    file.updatedAt = context.timestamp
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
    }

    /// 言語の順に並べる
    static func byLocale(_ texts: [LocalizedText]) -> [LocalizedText] {
        texts.sorted { $0.locale < $1.locale }
    }
}
