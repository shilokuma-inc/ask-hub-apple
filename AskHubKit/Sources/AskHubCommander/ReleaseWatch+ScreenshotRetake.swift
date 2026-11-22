import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 人が頼んだスクショの撮り直し（`retakeScreenshots`。`docs/renewal/store-screenshots.md` の「撮り直す」）。
///
/// 頼みを見つけたら、Actions の撮影の途中ならその実行を取り消し、記録の撮影を今の release ブランチの先頭で始め直す（頼みに `startedAt` を付ける）。
/// Actions で一部の組だけを撮り直すときは、ほかの組（見本と元の画像）を新しい撮影に引き継ぎ、撮り直す組だけを起動・取り込む。
/// UI テストの撮り方は、すべて撮り直す
extension ReleaseWatch {
    func startRetake(_ file: SubmissionFile, settings: RepositoryFile) async -> SubmissionFile {
        guard let branch = file.branch, let shots = file.screenshots, var retake = shots.retake, retake.startedAt == nil else {
            return file
        }
        let key = Self.screenshotKey(file)
        // 取り込んでいる・UI テストで撮っている Task は、終わってから撮り直す
        guard !capturing.contains(key) else { return file }
        if let id = shots.run?.id, shots.run?.isCompleted != true {
            do throws(PullRequestError) {
                try await hosting.cancelWorkflowRun(file.repo, id: id)
            } catch {
                report("\(file.repo) の \(file.version) のスクショの撮影（実行 \(id)）を取り消せない（\(error)）。撮り直しは続ける")
            }
        }
        var partial = false
        if case .actions? = settings.build?.storeScreenshots { partial = retake.isPartial }
        screenshotRunsCheckedAt[key] = nil
        let now = context.timestamp
        let started = await submissionStep(.screenshots, file) { file in
            var file = file
            retake.startedAt = now
            if partial {
                // 撮り直さない組を引き継ぐ（元の画像は、取り込むときに前のコミットの置き場所から写す）
                retake.from = shots.commit
                let carried = shots.sets.filter { !retake.covers(displayType: $0.displayType, locale: $0.locale) }
                file.screenshots = .init(state: .capturing, startedAt: now, sets: carried, retake: retake)
            } else {
                // UI テストの撮り方は、撮り始めに今の release ブランチの先頭を使う（Actions は起動するときに読む）
                let head = try await self.github { () throws(PullRequestError) in
                    try await self.hosting.branchHead(file.repo, branch: branch.name)
                }
                let commit = head.flatMap { ReleaseFile.isCommit($0) ? $0 : nil }
                file.screenshots = .init(state: .capturing, commit: commit, startedAt: now, retake: retake)
            }
            return file
        }
        if started.screenshots?.retake?.startedAt == now {
            log("\(file.repo) の \(file.version) のスクショを撮り直す（\(partial ? "一部の組" : "すべて")）")
        }
        return started
    }

    /// 撮り直す組だけの撮影の入力（`display_types`・`languages`）。頼みが無い・すべてなら、設定のすべて
    static func screenshotInputs(_ workflow: StoreScreenshotWorkflow, retake: SubmissionFile.Retake?) -> [String: String] {
        var inputs = screenshotInputs(workflow)
        guard let retake, retake.isPartial else { return inputs }
        if !retake.displayTypes.isEmpty {
            let names = workflow.artifacts.filter { retake.displayTypes.contains($0.key) }.values
            inputs["display_types"] = Set(names).sorted().joined(separator: ",")
        }
        if !retake.locales.isEmpty {
            let folders = workflow.languages.filter { retake.locales.contains($0.key) }.values.map(\.language)
            inputs["languages"] = Set(folders).sorted().joined(separator: ",")
        }
        return inputs
    }

    /// 引き継いだ組の差のある画面の元の画像を、前のコミットの置き場所から新しい撮影の置き場所に写す
    static func copyCarriedOriginals(_ sets: [SubmissionFile.ScreenshotSet], from: URL, to: URL) {
        for set in sets {
            for shot in set.shots where shot.changed {
                let target = StoreScreenshotTarget(displayType: set.displayType, locale: set.locale)
                let source = StoreScreenshotComparer.original(in: from, target: target, index: shot.index)
                let destination = StoreScreenshotComparer.original(in: to, target: target, index: shot.index)
                guard source != destination, FileManager.default.fileExists(atPath: source.path) else { continue }
                try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: destination)
                try? FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }
}
