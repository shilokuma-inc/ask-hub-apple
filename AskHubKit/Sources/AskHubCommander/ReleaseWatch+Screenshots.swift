import AskHubProtocol
import Foundation

/// リリースを始めた版の App Store のスクショ（`docs/renewal/release.md` の「スクショ」）。
/// release ブランチを作ったら撮り始めた印を書き、見回りの外の Task で撮って比べ、結果を記録に書く（UI テストは長いので、見回りを止めない）。
/// 撮り方（`build.storeScreenshots`）の無いリポジトリは撮らない。人が直す失敗は `failed` にし、スクショを変えずに審査に出せるようにする
extension ReleaseWatch {
    func prepareScreenshots(_ file: SubmissionFile, settings: RepositoryFile) async -> SubmissionFile {
        guard let branch = file.branch, file.screenshots?.state.isSettled != true else { return file }
        let key = Self.screenshotKey(file)
        guard !capturing.contains(key) else { return file }
        let now = context.timestamp
        guard let storeSettings = settings.build?.storeScreenshots, let build = settings.build?.xcode else {
            return await submissionStep(.screenshots, file) { file in
                var file = file
                file.screenshots = .init(state: .notConfigured, startedAt: now, finishedAt: now)
                return file
            }
        }
        guard screenshots != nil else {
            return await submissionStep(.screenshots, file) { file in
                var file = file
                file.screenshots = .init(
                    state: .failed, commit: branch.commit, startedAt: now, finishedAt: now, failure: "スクショを撮る道具が司令塔に無い"
                )
                return file
            }
        }
        var started = file
        if file.screenshots == nil {
            started = await submissionStep(.screenshots, file) { file in
                var file = file
                file.screenshots = .init(state: .capturing, commit: branch.commit, startedAt: now)
                return file
            }
            guard started.screenshots?.state == .capturing else { return started }
        }
        capturing.insert(key)
        let commit = started.screenshots?.commit ?? branch.commit
        captureTasks[key] = Task {
            await self.captureScreenshots(started, commit: commit, build: build, settings: storeSettings, repository: settings)
        }
        return started
    }

    /// 撮って比べ、結果を記録に書く（見回りの外で動く）。待てば直る失敗は、撮り始めた印のまま次の見回りでやり直す
    private func captureScreenshots(
        _ file: SubmissionFile,
        commit: String,
        build: BuildSettings,
        settings: StoreScreenshotSettings,
        repository: RepositoryFile
    ) async {
        let key = Self.screenshotKey(file)
        defer {
            capturing.remove(key)
            captureTasks[key] = nil
            wake()
        }
        guard let capturer = screenshots else { return }
        log("\(file.repo) の \(file.version) のスクショを撮り始める（\(commit.prefix(7))）")
        let result: SubmissionFile.StoreScreenshots
        do {
            let (store, app) = try await submissionApp(file.repo, settings: repository)
            let run = StoreScreenshotRun(context: context, store: store, capturer: capturer, sources: sources, log: log)
            result = try await run.execute(file, commit: commit, app: app, build: build, settings: settings)
        } catch let problem as ReleaseStepProblem where problem.needsHuman {
            result = .init(
                state: .failed,
                commit: commit,
                startedAt: file.screenshots?.startedAt ?? context.timestamp,
                finishedAt: context.timestamp,
                failure: problem.message
            )
        } catch {
            report("\(file.repo) の \(file.version) のスクショを撮れない（\(error)）。次の見回りでやり直す")
            return
        }
        _ = await submissionStep(.screenshots, file) { file in
            var file = file
            file.screenshots = result
            return file
        }
    }

    /// 撮っている Task が終わるのを待つ（テスト）
    func waitForScreenshotCaptures() async {
        for task in captureTasks.values { await task.value }
    }

    static func screenshotKey(_ file: SubmissionFile) -> String {
        "\(file.repo.rawValue)/\(file.version.rawValue)"
    }

    /// 撮り始めた印は、まだ何も無いときだけ書く。結果は、撮り始めた印（同じコミット）の上にだけ書き、`revision` を上げる。審査に出した後は変えない
    static func mergeScreenshots(_ changed: SubmissionFile, into file: inout SubmissionFile) {
        guard file.submit == nil, let screenshots = changed.screenshots else { return }
        if screenshots.state == .capturing {
            guard file.screenshots == nil else { return }
        } else {
            let isStarted = file.screenshots?.state == .capturing && file.screenshots?.commit == screenshots.commit
            guard file.screenshots == nil || isStarted else { return }
        }
        file.screenshots = screenshots
        if screenshots.state.isSettled { file.revision += 1 }
    }
}
