import AskHubProtocol
import Foundation

// MARK: - クリエイティブアセット（App Store のヘッダー・検索結果の画像）

extension StateIndex {
    struct CreativeEntry {
        /// 今の案の版（案が無ければ 0）
        var revision: Int
        /// 書き出し終えた今の案を、まだ承認していない
        var awaitsReview: Bool
        /// 頼んだ後、書き出し終えるまで（作っている途中は頼み直さない）
        var isWorking: Bool
    }
}

extension StateSnapshotBuilder {
    /// クリエイティブアセットの案と反映（リポジトリの順）。この端末が送って司令塔がまだ処理していない操作は、送った結果として先に出す
    /// （頼んだら次の案を書いている途中、承認したら承認済み）
    func creatives(index: inout StateIndex, overlaid: [IntentEnvelope]) -> [CreativeOverview] {
        var files = documents.creatives
        // まだ creative.json の無いリポジトリに頼んだ（最初の案）
        for envelope in overlaid where envelope.kind == DraftCreativeAssetsIntent.kind {
            guard let repo = envelope.repo, !files.contains(where: { $0.repo == repo }) else { continue }
            files.append(CreativeFile(repo: repo, updatedAt: envelope.issuedAt))
        }
        return files.map { file in
            var creative = Self.creative(file)
            // 古い順に当てる（頼んでから承認したときは、両方を当てる）
            for envelope in overlaid.reversed() where envelope.repo == file.repo {
                Self.apply(envelope, to: &creative)
            }
            index.creatives[creative.repositoryID] = StateIndex.CreativeEntry(
                revision: creative.draft?.revision ?? 0,
                awaitsReview: creative.awaitsReview,
                isWorking: creative.isWorking
            )
            return creative
        }
        .sorted { $0.repositoryID.localizedStandardCompare($1.repositoryID) == .orderedAscending }
    }

    static func creative(_ file: CreativeFile) -> CreativeOverview {
        CreativeOverview(
            repositoryID: repository(file.repo).id,
            draft: file.draft.map(draft),
            previous: file.previous.map { .init(revision: $0.revision, images: $0.images.map(image)) },
            approved: file.approved.map { approved in
                .init(
                    revision: approved.revision,
                    images: approved.images.map(image),
                    approvedAt: approved.at.date,
                    libraryTotal: approved.library?.total,
                    libraryReady: approved.library?.ready
                )
            },
            live: (file.live?.images ?? []).compactMap { live in
                URL(string: live.url).map { .init(locale: live.locale, kind: kind(live.kind), screenshot: .remote($0)) }
            },
            problem: file.problem,
            updatedAt: file.updatedAt.date
        )
    }

    private static func draft(_ draft: CreativeFile.Draft) -> CreativeOverview.Draft {
        let state: CreativeOverview.DraftState = switch draft.state {
        case .drafting: .drafting
        case .rendering: .rendering
        case .rendered: .rendered
        case .failed: .failed
        }
        var titles: [String: String] = [:]
        for localization in draft.spec?.locales ?? [] {
            titles[localization.locale] = localization.header.title.replacingOccurrences(of: "*", with: "")
        }
        return CreativeOverview.Draft(
            revision: draft.revision,
            state: state,
            comment: draft.request.comment,
            requestedAt: draft.request.at.date,
            reason: draft.reason,
            titles: titles,
            images: draft.images.map(image),
            problems: draft.problems.map(problem),
            failure: draft.failure,
            runURL: draft.run?.url.flatMap(URL.init(string:))
        )
    }

    private static func image(_ image: CreativeFile.Image) -> CreativeOverview.Image {
        .init(locale: image.locale, kind: kind(image.kind), screenshot: .stored(image.preview), problems: image.problems.map(problem))
    }

    private static func problem(_ problem: CreativeProblem) -> CreativeOverview.Problem {
        .init(code: problem.code, message: problem.message)
    }

    private static func kind(_ kind: CreativeKind) -> CreativeOverview.Kind {
        switch kind {
        case .productPageHeader: .productPageHeader
        case .searchResults: .searchResults
        }
    }

    /// 処理を待つ意図を、送った結果として当てる
    private static func apply(_ envelope: IntentEnvelope, to creative: inout CreativeOverview) {
        switch envelope.kind {
        case DraftCreativeAssetsIntent.kind:
            guard let intent = try? DraftCreativeAssetsIntent(envelope: envelope), intent.revision == (creative.draft?.revision ?? 0) else {
                return
            }
            if let old = creative.draft, old.state == .rendered {
                creative.previous = .init(revision: old.revision, images: old.images)
            }
            creative.draft = .init(
                revision: intent.revision + 1, state: .drafting, comment: intent.comment, requestedAt: envelope.issuedAt.date
            )
            creative.problem = nil

        case ApproveCreativeAssetsIntent.kind:
            guard let intent = try? ApproveCreativeAssetsIntent(envelope: envelope), let draft = creative.draft,
                  draft.revision == intent.revision, draft.state == .rendered else { return }
            creative.approved = .init(revision: draft.revision, images: draft.images, approvedAt: envelope.issuedAt.date)

        default:
            break
        }
    }

    /// クリエイティブアセットの意図の呼び名。どれでもなければ nil
    static func creativeLabel(_ envelope: IntentEnvelope) -> String? {
        let name = envelope.repo?.name ?? ""
        switch envelope.kind {
        case DraftCreativeAssetsIntent.kind:
            let comment = envelope.payload?["comment"] != nil
            return (envelope.targetVersion == "0" ? "ヘッダーと検索結果の案を頼む" : comment ? "ヘッダーと検索結果の案の直し" : "ヘッダーと検索結果の案を作り直す")
                + "（\(name)）"
        case ApproveCreativeAssetsIntent.kind:
            return "ヘッダーと検索結果の案 \(envelope.targetVersion ?? "") の承認（\(name)）"
        default:
            return nil
        }
    }
}
