import AskHubProtocol
import AskHubStateStore
import Foundation

/// 撮り方（`build.storeScreenshots`）の無いリポジトリのスクショ（`docs/renewal/store-screenshots.md` の「撮影の設定の漏れを防ぐ」）。
///
/// app-kit の撮影のワークフローを使うなら、base の先頭の `AppStore/` のファイルと App Store Connect のリファレンスデータから撮り方を組み立て
/// （`StoreScreenshotSettingsBuilder`）、`build.storeScreenshots` に書いてから撮影を起動する。release ブランチのファイルからは作らない
/// （撮り方はリリースをまたいで使う。hotfix の release ブランチは古い言語の並びのことがある）。
/// 使わなければ撮らない（`notConfigured`）。使うのに作れなければ `failed` にし、人が直してから「スクショを撮る」で撮る。わけはどちらも記録に書く
extension ReleaseWatch {
    /// 撮り方を組み立てた結果
    enum ScreenshotSettingsOutcome: Equatable {
        case made(StoreScreenshotWorkflow)
        /// app-kit の撮影を使わない（撮らない）
        case notUsed(String)
        /// 使うのに作れない（人が直す）
        case refused(String)
    }

    static let screenshotWorkflowUnused = "撮り方の設定（build.storeScreenshots）が無く、app-kit の撮影のワークフローも使っていないので、撮らなかった"

    func configureScreenshots(_ file: SubmissionFile, settings: RepositoryFile) async -> SubmissionFile {
        let outcome: ScreenshotSettingsOutcome
        do {
            outcome = try await screenshotSettings(for: settings)
        } catch let problem as ReleaseStepProblem where problem.needsHuman {
            outcome = .refused(problem.message)
        } catch {
            report("\(file.repo) の \(file.version) のスクショの撮り方を作れない（\(error)）。次の見回りでやり直す")
            return file
        }
        let workflow: StoreScreenshotWorkflow
        switch outcome {
        case let .made(made): workflow = made
        case let .notUsed(reason): return await settleScreenshots(file, state: .notConfigured, reason: reason)
        case let .refused(reason): return await settleScreenshots(file, state: .failed, reason: reason)
        }
        let saved: RepositoryFile
        do {
            let message = "\(file.repo) の撮影の設定を作る"
            saved = try await context.files.update(RepositoryFile.self, at: StatePath.repository(file.repo), message: message) {
                guard $0.build != nil, $0.build?.storeScreenshots == nil else { return false }
                $0.build?.storeScreenshots = .actions(workflow)
                return true
            }.file
        } catch {
            report("\(file.repo) の撮影の設定を書けない（\(error)）。次の見回りでやり直す")
            return file
        }
        // 読んだ後に人かずれの点検が書いていたら、そちらで撮る
        guard case let .actions(written)? = saved.build?.storeScreenshots else { return file }
        if written == workflow {
            log("\(file.repo) の撮影の設定を作った（\(StoreScreenshotSettingsBuilder.summary(workflow))）。\(file.version) のスクショを撮る")
        }
        return await advanceScreenshotWorkflow(file, workflow: written, settings: saved)
    }

    /// base の先頭のファイルとリファレンスデータから、撮り方を組み立てる。待てば直る失敗（GitHub・App Store Connect）は投げる
    func screenshotSettings(for settings: RepositoryFile) async throws -> ScreenshotSettingsOutcome {
        let observed = try await hosting.appKitObserved(settings.repo, base: settings.build?.baseBranch)
        guard observed.callerRef != nil, let sources = observed.screenshotSources else { return .notUsed(Self.screenshotWorkflowUnused) }
        guard settings.build != nil else {
            return .refused("ビルドの設定（build）が無いので、撮り方の設定を作れない。ビルドの設定を入れてから、スクショを撮る")
        }
        guard let store = stores.first else {
            return .refused("App Store Connect の鍵が司令塔に無いので、撮り方の設定を作れない（askhub-commander app-store-connect で入れる）")
        }
        let groups = try await appStoreConnect { () throws(AppStoreConnectError) in try await store.placementProfileGroups() }
        let builder = StoreScreenshotSettingsBuilder.self
        switch builder.build(screenshots: sources.screenshots, languages: sources.languages, groups: groups) {
        case let .success(built): return .made(built.workflow)
        case let .failure(problem):
            return .refused(String(problem.description.dropFirst(builder.problemPrefix.count)) + "。直してから、スクショを撮る")
        }
    }

    /// 撮らずに決着させる（わけを書く）。撮り直しを始めた記録なら、同じ撮影（撮り始めの時刻）の上に書く
    private func settleScreenshots(_ file: SubmissionFile, state: SubmissionFile.ScreenshotState, reason: String) async -> SubmissionFile {
        let now = context.timestamp
        return await submissionStep(.screenshots, file) { file in
            var file = file
            let current = file.screenshots
            file.screenshots = .init(
                state: state, commit: current?.commit, startedAt: current?.startedAt ?? now, finishedAt: now, failure: reason
            )
            return file
        }
    }
}
