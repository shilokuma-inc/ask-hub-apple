import AskHubClient
import AskHubProtocol
import Foundation

// MARK: - リリースを始めてから配信まで

extension StateIntentMapper {
    /// リリースの操作を送れるか。始めるのは、対象のリポジトリで終わっていないリリースが無く、配信した版より大きい版だけ。
    /// ほかは、最後に読んだ状態でその操作を出しているときだけ（審査に出す・配信する・取り下げ・やめる）
    func supportsSubmissionIntent(_ intent: HumanIntent) -> Bool {
        switch intent {
        case let .startRelease(repositoryID, version):
            guard index.repositories[repositoryID] != nil, !index.releasingRepositories.contains(repositoryID),
                  let version = MarketingVersion(rawValue: version) else { return false }
            return index.releasedVersions[repositoryID].map { version > $0 } ?? true

        case let .submitForReview(repositoryID, version, _):
            return index.submissions[Submission.id(repositoryID, version)]?.canSubmit == true

        case let .distributeRelease(repositoryID, version):
            return index.submissions[Submission.id(repositoryID, version)]?.canDistribute == true

        case let .withdrawSubmission(repositoryID, version):
            return index.submissions[Submission.id(repositoryID, version)]?.canWithdraw == true

        case let .abandonRelease(repositoryID, version):
            return index.submissions[Submission.id(repositoryID, version)]?.canAbandon == true

        default:
            return false
        }
    }

    func submissionDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .startRelease(repositoryID, version):
            guard let parsed = MarketingVersion(rawValue: version) else {
                throw ClientServiceError(message: "版は 1.2.0 のように、数を . でつないで書いてください")
            }
            guard supportsSubmissionIntent(intent) else {
                throw ClientServiceError(message: "このリポジトリでは、いまはリリースを始められません（終わっていないリリースがあるか、配信した版より大きくありません）")
            }
            return .startRelease(try repository(repositoryID), version: parsed)

        case let .submitForReview(repositoryID, version, request):
            let entry = try entry(repositoryID, version, \.canSubmit, unavailable: "この版は、いまは審査に出せません。取り直してから送ってください")
            guard entry.revision == request.revision else {
                throw ClientServiceError(message: "ビルドか What's New の下書きが変わりました。見直してから審査に出してください")
            }
            return .submitForReview(
                entry.target,
                revision: request.revision,
                builds: try Self.builds(request.builds, available: entry.builds),
                whatsNew: try Self.whatsNew(request.whatsNew, locales: entry.locales),
                releaseType: Self.releaseType(request.releaseType),
                earliestReleaseDate: try Self.releaseDate(request.releaseType)
            )

        case let .distributeRelease(repositoryID, version):
            let entry = try entry(repositoryID, version, \.canDistribute, unavailable: "この版は、いまは配信できません")
            return .distributeRelease(entry.target)

        case let .withdrawSubmission(repositoryID, version):
            let entry = try entry(repositoryID, version, \.canWithdraw, unavailable: "この版は、いまは審査を取り下げられません")
            return .withdrawSubmission(entry.target)

        case let .abandonRelease(repositoryID, version):
            let entry = try entry(repositoryID, version, \.canAbandon, unavailable: "このリリースは、いまはやめられません（審査中か、審査に通っています）")
            return .abandonRelease(entry.target)

        default:
            throw Self.unsupported
        }
    }

    private func entry(
        _ repositoryID: TargetRepository.ID,
        _ version: String,
        _ allowed: KeyPath<StateIndex.SubmissionEntry, Bool>,
        unavailable: String
    ) throws(ClientServiceError) -> StateIndex.SubmissionEntry {
        guard let entry = index.submissions[Submission.id(repositoryID, version)], entry[keyPath: allowed] else {
            throw ClientServiceError(message: unavailable)
        }
        return entry
    }

    /// 出すビルド。release ブランチから上げたビルドのうち、選んだプラットフォームのもの
    private static func builds(
        _ builds: [Submission.Build],
        available: [SubmissionFile.BuildChoice]
    ) throws(ClientServiceError) -> [SubmissionFile.BuildChoice] {
        guard !builds.isEmpty else { throw ClientServiceError(message: "審査に出すプラットフォームを選んでください") }
        return try builds.map { build throws(ClientServiceError) in
            guard let choice = available.first(where: { $0.platform.rawValue == build.platform && $0.build == build.build }) else {
                throw ClientServiceError(message: "ビルド \(build.platform) (\(build.build)) は審査に出せません。取り直してから送ってください")
            }
            return choice
        }
    }

    /// 人が確かめた What's New。下書きと同じ言語をそろえ、空白だけの文は送らない（司令塔と同じく Unicode のコードポイントで数える）
    private static func whatsNew(_ texts: [Submission.Localized], locales: [String]) throws(ClientServiceError) -> [LocalizedText] {
        guard Set(texts.map(\.locale)) == Set(locales) else {
            throw ClientServiceError(message: "What's New の言語が下書きと違います。取り直してから送ってください")
        }
        return try locales.map { locale throws(ClientServiceError) in
            let text = texts.first { $0.locale == locale }?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty, text.unicodeScalars.count <= LocalizedText.whatsNewLimit else {
                throw ClientServiceError(message: "What's New（\(locale)）は 1〜\(LocalizedText.whatsNewLimit) 文字で書いてください")
            }
            return LocalizedText(locale: locale, text: text)
        }
    }

    private static func releaseType(_ type: Submission.ReleaseType) -> AppStoreReleaseType {
        switch type {
        case .afterApproval: .afterApproval
        case .manual: .manual
        case .scheduled: .scheduled
        }
    }

    private static func releaseDate(_ type: Submission.ReleaseType) throws(ClientServiceError) -> Timestamp? {
        guard case .scheduled(let date) = type else { return nil }
        guard date > Date() else { throw ClientServiceError(message: "配信の日時は、これから先の日時にしてください") }
        return Timestamp(date)
    }
}
