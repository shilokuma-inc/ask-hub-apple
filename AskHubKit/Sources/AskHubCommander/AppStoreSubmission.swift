import AskHubProtocol
import Foundation

/// 1 つの版を、プラットフォームごとに審査に出す（`docs/renewal/release.md` の「リリースを始めてから配信まで」の 7）。
/// 編集できる版を作るか直し（版の番号・配信の方式・ビルド）、What's New と掲載文の直しを書き、reviewSubmission に版を足して提出する。
/// どれも、する前に今の様子を読み、途中で止まってもやり直せば同じになる
struct AppStoreSubmission: Sendable {
    var store: any AppStoreConnectSubmitting
    var app: AppStoreApp
    var version: MarketingVersion
    var request: SubmissionFile.Submit

    /// `build` のプラットフォームを審査に出し、出した後の状態を返す。`versions` はアプリの版（出す前に読んだもの）
    func send(_ build: AppStoreBuild, versions: [AppStoreVersionInfo]) async throws -> AppStoreVersionState {
        let platform = build.platform
        let mine = versions.filter { $0.platform == platform && $0.versionString == version.rawValue }
        // 前の試行が出し終えた後に落ちた（記録する前）
        if let sent = mine.first(where: { $0.state.isInFlight }) { return sent.state }
        let target = try await prepareVersion(build, mine: mine, versions: versions)
        try await writeTexts(of: target)
        return try await sendForReview(target)
    }

    /// 編集できる版があれば、版の番号ごと直して使う（やめたリリースの版・手で作った版）。無ければ作る
    private func prepareVersion(
        _ build: AppStoreBuild,
        mine: [AppStoreVersionInfo],
        versions: [AppStoreVersionInfo]
    ) async throws -> AppStoreVersionInfo {
        let change = AppStoreVersionChange(
            version: version,
            releaseType: request.releaseType,
            earliestReleaseDate: request.earliestReleaseDate?.date,
            buildID: build.id
        )
        if let editable = mine.first(where: \.isEditable) ?? versions.first(where: { $0.platform == build.platform && $0.isEditable }) {
            try await call { () throws(AppStoreConnectError) in try await store.updateVersion(editable.id, change) }
            return editable
        }
        return try await call { () throws(AppStoreConnectError) in
            try await store.createVersion(of: app.id, platform: build.platform, change)
        }
    }

    /// 人が確かめた What's New と掲載文の直しを、言語ごとに書く（今の文と同じ欄は書かない。確かめなかった欄は App Store Connect の文を残す）。
    /// 書く前に、直した後の掲載文でどの言語にも説明文とキーワードがそろうかを確かめ、そろわなければ書かずに止める
    /// （App Store Connect は空の版を審査に出させない。初めての版で、後から足したプラットフォームの版や、人が「変える」を外した欄が空のまま残ることがある）
    private func writeTexts(of target: AppStoreVersionInfo) async throws {
        let changes = request.listing ?? []
        let localizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: target.id) }
        let missing = Self.missingRequired(localizations, changes: changes)
        guard missing.isEmpty else {
            throw ReleaseStepProblem(
                "\(target.platform.rawValue) の版の掲載文に、\(missing.joined(separator: "・")) が無い。App Store Connect で書く（書けば次の見回りで出し直す）",
                needsHuman: true
            )
        }
        func localization(_ locale: String) throws -> AppStoreLocalization {
            guard let localization = localizations.first(where: { $0.locale == locale }) else {
                throw ReleaseStepProblem(
                    "\(target.platform.rawValue) の版に \(locale) の掲載文が無い。App Store Connect で言語を確かめる", needsHuman: true
                )
            }
            return localization
        }
        for text in request.whatsNew {
            let localization = try localization(text.locale)
            guard localization.whatsNew != text.text else { continue }
            try await call { () throws(AppStoreConnectError) in try await store.updateWhatsNew(localization.id, text: text.text) }
        }
        for change in changes {
            let localization = try localization(change.locale)
            var update = ListingText(locale: change.locale)
            for field in ListingText.Field.allCases {
                guard let text = change[field], text != (localization.listing[field] ?? "") else { continue }
                update[field] = text
            }
            guard !update.isEmpty else { continue }
            try await call { () throws(AppStoreConnectError) in try await store.updateListing(localization.id, update) }
        }
    }

    /// 人の直しを当てた後で、説明文かキーワードが空の言語と欄（「ja の description」など）
    static func missingRequired(_ localizations: [AppStoreLocalization], changes: [ListingText]) -> [String] {
        localizations.flatMap { localization in
            let change = changes.first { $0.locale == localization.locale }
            return [ListingText.Field.description, .keywords].compactMap { field in
                let text = change?[field] ?? localization.listing[field] ?? ""
                return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(localization.locale) の \(field.rawValue)" : nil
            }
        }
    }

    /// 開いている（出す前の）提出を使うか作り、版を足して提出する
    private func sendForReview(_ target: AppStoreVersionInfo) async throws -> AppStoreVersionState {
        let platform = target.platform
        let submissions = try await call { () throws(AppStoreConnectError) in
            try await store.reviewSubmissions(of: app.id, platform: platform)
        }
        if let sent = submissions.first(where: { $0.versionID == target.id && ($0.state == .waitingForReview || $0.state == .inReview) }) {
            return sent.state == .inReview ? .inReview : .waitingForReview
        }
        if submissions.contains(where: { $0.state == .unresolvedIssues }) {
            throw ReleaseStepProblem("\(platform.rawValue) に、審査で断られたままの提出が残っている。App Store Connect で確かめる", needsHuman: true)
        }
        let draft: AppStoreReviewSubmission
        if let open = submissions.first(where: { $0.state == .readyForReview }) {
            if let other = open.versionID, other != target.id {
                throw ReleaseStepProblem("\(platform.rawValue) の出す前の提出に、ほかの版が入っている。App Store Connect で確かめる", needsHuman: true)
            }
            draft = open
        } else {
            draft = try await call { () throws(AppStoreConnectError) in
                try await store.createReviewSubmission(of: app.id, platform: platform)
            }
        }
        if draft.versionID != target.id {
            try await call { () throws(AppStoreConnectError) in try await store.addToReviewSubmission(draft.id, versionID: target.id) }
        }
        try await call { () throws(AppStoreConnectError) in try await store.submitReviewSubmission(draft.id) }
        return .waitingForReview
    }

    private func call<Value>(_ body: () async throws(AppStoreConnectError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw ReleaseWatch.problem(error)
        }
    }
}
