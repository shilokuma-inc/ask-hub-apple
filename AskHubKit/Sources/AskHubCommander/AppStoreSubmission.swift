import AskHubProtocol
import Foundation

/// 1 つの版を、プラットフォームごとに審査に出す（`docs/renewal/release.md` の「リリースを始めてから配信まで」の 7）。
/// 編集できる版を作るか直し（版の番号・配信の方式・ビルド）、What's New を書き、reviewSubmission に版を足して提出する。
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
        try await writeWhatsNew(of: target)
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

    /// 人が確かめた What's New を、言語ごとに書く（同じ文なら書かない）
    private func writeWhatsNew(of target: AppStoreVersionInfo) async throws {
        guard !request.whatsNew.isEmpty else { return }
        let localizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: target.id) }
        for text in request.whatsNew {
            guard let localization = localizations.first(where: { $0.locale == text.locale }) else {
                throw ReleaseStepProblem(
                    "\(target.platform.rawValue) の版に \(text.locale) の掲載文が無い。App Store Connect で言語を確かめる", needsHuman: true
                )
            }
            guard localization.whatsNew != text.text else { continue }
            try await call { () throws(AppStoreConnectError) in try await store.updateWhatsNew(localization.id, text: text.text) }
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
