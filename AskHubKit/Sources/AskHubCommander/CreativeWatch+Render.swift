import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// クリエイティブアセットの書き出し: ワークフローの起動・見張り・取り込みと、記録の書き直し（`CreativeWatch`）
extension CreativeWatch {
    // MARK: - 書き出し

    func advanceCreativeRender(_ file: CreativeFile, draft: CreativeFile.Draft, settings: RepositoryFile) async {
        guard let spec = draft.spec else { return }
        let key = Self.creativeKey(file.repo, revision: draft.revision)
        let base = Self.creativeBase(settings)
        // 待てば直る失敗（上限・GitHub の障害）の後は、決めた時刻まで GitHub に送らない
        if let until = notBefore[key], context.now() < until { return }
        guard let run = draft.run else {
            await startCreativeRender(file, draft: draft, spec: spec, base: base)
            return
        }
        if let checked = checkedAt[key], context.now().timeIntervalSince(checked) < Self.creativeRunCheckInterval { return }
        if run.isCompleted {
            // 一覧から見つけ直した実行も、書き出せた（success）ときだけ取り込む
            if run.conclusion == "success" {
                startCreativeImport(file, draft: draft, run: run)
            } else {
                await finishCreativeRun(file.repo, draft: draft, run: run, conclusion: run.conclusion)
            }
            return
        }
        checkedAt[key] = context.now()
        if run.id == nil {
            await findCreativeRun(file, draft: draft, spec: spec, run: run, base: base)
        } else {
            await watchCreativeRun(file, draft: draft, run: run)
        }
    }

    /// 前の実行の 6.9 インチの画面が残っていれば使い回し、起動の印（`run.dispatchedAt`）を書いてから起動する
    func startCreativeRender(_ file: CreativeFile, draft: CreativeFile.Draft, spec: CreativeSpec, base: String) async {
        let repo = file.repo
        let now = context.timestamp
        let after: Int
        var reuse: Int?
        do throws(PullRequestError) {
            let existing = try await hosting.dispatchedRuns(repo, workflow: Self.creativeWorkflow, branch: base)
            after = ReleaseWatch.matching(existing, workflow: Self.creativeWorkflow, branch: base).map(\.id).max() ?? 0
            if let previous = draft.screenshotsRun {
                do throws(PullRequestError) {
                    let artifacts = try await hosting.runArtifacts(repo, runID: previous)
                    reuse = artifacts.contains { $0.name == Self.creativeScreenshotsArtifact && !$0.expired } ? previous : nil
                } catch .notFound {
                    // 前の実行が消された。使い回さずに撮り直す
                    reuse = nil
                }
            }
        } catch {
            // ワークフローが無い（404）などは起動と同じわけで止め、待てば直る失敗は時刻を空けてやり直す
            if let reason = Self.lastingCreativeDispatchFailure(error) {
                await failCreativeDraft(repo, revision: draft.revision, reason)
            } else {
                holdCreative(repo, revision: draft.revision, after: error)
            }
            return
        }
        let screenshots = reuse
        let marked = await updateCreativeDraft(repo, revision: draft.revision, message: "\(repo) のクリエイティブアセットの書き出しを始める") { draft in
            guard draft.state == .rendering, draft.run == nil else { return false }
            draft.run = .init(dispatchedAt: now, after: after)
            draft.screenshotsRun = screenshots
            return true
        }
        guard let markedDraft = marked?.draft, markedDraft.run?.dispatchedAt == now else { return }
        await dispatchCreativeRender(file, draft: markedDraft, spec: spec, base: base)
    }

    /// 書き出しのワークフローを起動し、実行の id を書く。古い形の応答（id なし）なら、次の見回りで一覧から探す
    func dispatchCreativeRender(_ file: CreativeFile, draft: CreativeFile.Draft, spec: CreativeSpec, base: String) async {
        let repo = file.repo
        checkedAt[Self.creativeKey(repo, revision: draft.revision)] = context.now()
        let json: String
        do {
            json = try spec.inputJSON()
        } catch {
            await failCreativeDraft(repo, revision: draft.revision, "案を書き出しの入力にできない（\(error)）")
            return
        }
        let inputs = ["spec": json, "screenshots_run": draft.screenshotsRun.map(String.init) ?? ""]
        guard inputs.values.reduce(0, { $0 + $1.count }) <= Self.dispatchInputLimit else {
            await failCreativeDraft(repo, revision: draft.revision, "案が大きすぎて、書き出しのワークフローの入力に入らない（言語を減らす）")
            return
        }
        let dispatched: DispatchedRun?
        do throws(PullRequestError) {
            dispatched = try await hosting.dispatchWorkflow(repo, workflow: Self.creativeWorkflow, ref: base, inputs: inputs)
        } catch {
            guard let reason = Self.lastingCreativeDispatchFailure(error) else {
                holdCreative(repo, revision: draft.revision, after: error)
                return
            }
            await failCreativeDraft(repo, revision: draft.revision, reason)
            return
        }
        let which = dispatched.map { "実行 \($0.id)" } ?? "実行の id は次の見回りで探す"
        let screens = draft.screenshotsRun.map { "実行 \($0) の画面を使う" } ?? "6.9 インチを撮る"
        log("\(repo) のクリエイティブアセットの案 \(draft.revision) の書き出しを \(base) で起動した（\(which)、\(screens)）")
        guard let dispatched else { return }
        await updateCreativeDraft(repo, revision: draft.revision, message: "\(repo) のクリエイティブアセットの書き出しの実行") { draft in
            guard draft.state == .rendering, var run = draft.run, run.id == nil else { return false }
            run.id = dispatched.id
            run.url = dispatched.url?.absoluteString
            draft.run = run
            return true
        }
    }

    /// 起動した後に id を書けなかった実行を、既定のブランチの `workflow_dispatch` の実行から探す。見つからないまま 5 分たてば送り直す
    func findCreativeRun(
        _ file: CreativeFile,
        draft: CreativeFile.Draft,
        spec: CreativeSpec,
        run: WorkflowRunRecord,
        base: String
    ) async {
        let repo = file.repo
        let runs: [WorkflowRunDetail]
        do {
            runs = try await github { () throws(PullRequestError) in
                try await self.hosting.dispatchedRuns(repo, workflow: Self.creativeWorkflow, branch: base)
            }
        } catch {
            report("\(repo) のクリエイティブアセットの書き出しの実行を探せない（\(error)）。次の見回りでやり直す")
            return
        }
        switch ReleaseWatch.dispatchedRun(in: runs, workflow: Self.creativeWorkflow, branch: base, run: run) {
        case let .found(found):
            await updateCreativeDraft(repo, revision: draft.revision, message: "\(repo) のクリエイティブアセットの書き出しの実行") { draft in
                guard draft.state == .rendering, draft.run == run else { return false }
                draft.run = ReleaseWatch.record(found, dispatchedAt: run.dispatchedAt, previous: run)
                return true
            }
        case let .ambiguous(ids):
            let list = ids.map(String.init).joined(separator: "・")
            await failCreativeDraft(repo, revision: draft.revision, "書き出しの実行を見分けられない（起動の後に、同じワークフローの実行が \(list) とほかにもある）")
        case .none:
            guard context.now().timeIntervalSince(run.dispatchedAt.date) >= Self.creativeRedispatchAfter else { return }
            // 送り直しても見つからないまま、案を書き終えてから打ち切りの時間がたったら、送り直すのをやめる（見つけていない実行は取り消せない）
            if let drafted = draft.draftedAt, context.now().timeIntervalSince(drafted.date) >= Self.creativeRunTimeout {
                let hours = Int(Self.creativeRunTimeout / 3600)
                await failCreativeDraft(repo, revision: draft.revision, "書き出しの実行が \(hours) 時間たっても見つからない（起動が届いていない）。案を作り直す")
                return
            }
            let now = context.timestamp
            let marked = await updateCreativeDraft(repo, revision: draft.revision, message: "\(repo) のクリエイティブアセットの書き出しを送り直す") { draft in
                guard draft.state == .rendering, draft.run == run else { return false }
                draft.run = .init(dispatchedAt: now, after: run.after)
                return true
            }
            guard let markedDraft = marked?.draft, markedDraft.run?.dispatchedAt == now else { return }
            await dispatchCreativeRender(file, draft: markedDraft, spec: spec, base: base)
        }
    }

    /// 実行を読み、様子が変わったら書く。3 時間で終わらなければ取り消して `failed` にする。終わったら取り込む
    func watchCreativeRun(_ file: CreativeFile, draft: CreativeFile.Draft, run: WorkflowRunRecord) async {
        guard let id = run.id else { return }
        let repo = file.repo
        let detail: WorkflowRunDetail
        do {
            detail = try await github { () throws(PullRequestError) in try await self.hosting.workflowRun(repo, id: id) }
        } catch let problem as ReleaseStepProblem where problem.needsHuman {
            await failCreativeDraft(repo, revision: draft.revision, "書き出しの実行 \(id) を読めない（\(problem.message)）")
            return
        } catch {
            report("\(repo) のクリエイティブアセットの書き出しの実行 \(id) を読めない（\(error)）。次の見回りでやり直す")
            return
        }
        let updated = ReleaseWatch.record(detail, dispatchedAt: run.dispatchedAt, previous: run)
        if detail.isCompleted {
            await finishCreativeRun(repo, draft: draft, run: updated, conclusion: detail.conclusion)
        } else {
            await continueCreativeRun(repo, draft: draft, run: run, updated: updated)
        }
    }

    /// 終わっていない実行。様子が変わったときだけ書き、3 時間で終わらなければ取り消す
    func continueCreativeRun(
        _ repo: RepositoryFullName,
        draft: CreativeFile.Draft,
        run: WorkflowRunRecord,
        updated: WorkflowRunRecord
    ) async {
        guard let id = run.id else { return }
        guard context.now().timeIntervalSince(run.dispatchedAt.date) >= Self.creativeRunTimeout else {
            guard updated != run else { return }
            await updateCreativeDraft(repo, revision: draft.revision, message: "\(repo) のクリエイティブアセットの書き出しの様子") { draft in
                guard draft.state == .rendering, draft.run?.id == id else { return false }
                draft.run = updated
                return true
            }
            return
        }
        let hours = Int(Self.creativeRunTimeout / 3600)
        do throws(PullRequestError) {
            try await hosting.cancelWorkflowRun(repo, id: id)
        } catch .conflict {
            // 読んだ後に終わった。次の見回りで終わった実行として読む
            return
        } catch {
            guard !ReleaseWatch.isTransient(error) else { return }
            let message = "書き出しの実行 \(id) が \(hours) 時間で終わらないが、取り消せない（\(error)）。GitHub で取り消す"
            await failCreativeDraft(repo, revision: draft.revision, message)
            return
        }
        await failCreativeDraft(repo, revision: draft.revision, "書き出しの実行 \(id) が \(hours) 時間で終わらないので取り消した")
    }

    /// 終わった実行。書き出せたら取り込み、書き出せなかったら `report.json` のわけ（あれば）で `failed` にする
    func finishCreativeRun(_ repo: RepositoryFullName, draft: CreativeFile.Draft, run: WorkflowRunRecord, conclusion: String?) async {
        guard let id = run.id else { return }
        log("\(repo) のクリエイティブアセットの書き出し（実行 \(id)）が終わった（\(conclusion ?? "結論なし")）")
        guard conclusion == "success" else {
            var why: String?
            if conclusion == "failure" { why = await creativeImport(repo, revision: draft.revision)?.failure(of: repo, runID: id) }
            let message = why.map { "書き出せなかった（\(String($0.prefix(500)))）" }
                ?? "書き出しの実行 \(id) が \(conclusion ?? "結論なし") で終わった（\(run.url ?? "実行の画面")）"
            await failCreativeDraft(repo, revision: draft.revision, message, run: run)
            return
        }
        let saved = await updateCreativeDraft(repo, revision: draft.revision, message: "\(repo) のクリエイティブアセットの書き出しが終わった") { draft in
            guard draft.state == .rendering, draft.run?.id == id else { return false }
            draft.run = run
            return true
        }
        if let saved, let savedDraft = saved.draft, savedDraft.run?.isCompleted == true {
            startCreativeImport(saved, draft: savedDraft, run: run)
        }
    }

    // MARK: - 取り込み

    /// 書き出しの道具（元の画像の置き場所が無ければ nil）
    func creativeImport(_ repo: RepositoryFullName, revision: Int) -> CreativeImport? {
        guard let root = originals else { return nil }
        return CreativeImport(
            store: context.store,
            hosting: hosting,
            extractor: artifacts,
            originals: root.appendingPathComponent("\(repo.owner)/\(repo.name)/\(revision)", isDirectory: true),
            log: log
        )
    }

    /// 書き出し終えた実行の artifact を、見回りの外の Task で取り込む（落とすのに数分かかる）。取り込んでいる間は始めない
    func startCreativeImport(_ file: CreativeFile, draft: CreativeFile.Draft, run: WorkflowRunRecord) {
        let key = Self.creativeKey(file.repo, revision: draft.revision)
        guard !inFlight.contains(key), let id = run.id, let spec = draft.spec else { return }
        inFlight.insert(key)
        tasks[key] = Task { await self.importCreative(file.repo, draft: draft, spec: spec, runID: id) }
    }

    func importCreative(_ repo: RepositoryFullName, draft: CreativeFile.Draft, spec: CreativeSpec, runID: Int) async {
        let key = Self.creativeKey(repo, revision: draft.revision)
        var settled = false
        defer {
            inFlight.remove(key)
            tasks[key] = nil
            if settled { wake() }
        }
        checkedAt[key] = context.now()
        guard let importer = creativeImport(repo, revision: draft.revision) else {
            settled = true
            await failCreativeDraft(repo, revision: draft.revision, "書き出した画像を置く場所が司令塔に無い")
            return
        }
        let imported: CreativeImport.Imported
        do {
            imported = try await importer.execute(repo, revision: draft.revision, spec: spec, runID: runID)
        } catch let problem as ReleaseStepProblem where problem.needsHuman {
            settled = true
            await failCreativeDraft(repo, revision: draft.revision, problem.message)
            return
        } catch {
            report("\(repo) のクリエイティブアセットの書き出し（実行 \(runID)）を取り込めない（\(error)）。次の見回りでやり直す")
            return
        }
        settled = true
        // 6.9 インチを撮ったのが前の実行でなければ、この実行で撮った（次の案で使い回す）
        let screenshots = draft.screenshotsRun ?? runID
        let message = "\(repo) のクリエイティブアセットの案 \(draft.revision) を書き出した"
        let saved = await updateCreativeDraft(repo, revision: draft.revision, message: message) { draft in
            guard draft.state == .rendering, draft.run?.id == runID else { return false }
            draft.images = imported.images
            draft.problems = imported.problems
            draft.screenshotsRun = screenshots
            draft.state = .rendered
            return true
        }
        if saved?.draft?.state == .rendered {
            log("\(repo) のクリエイティブアセットの案 \(draft.revision) を取り込んだ（\(imported.images.count) 枚）。人が確かめる番")
        }
    }

    // MARK: - 記録

    /// 今の案を書き直す。案の版が変わっていれば（人が新しい案を頼んだ）書かない。書けなければ知らせて次の見回りでやり直す
    @discardableResult
    nonisolated func updateCreativeDraft(
        _ repo: RepositoryFullName,
        revision: Int,
        message: String,
        _ change: @escaping @Sendable (inout CreativeFile.Draft) -> Bool
    ) async -> CreativeFile? {
        let path = StatePath.creative(repo)
        let now = context.timestamp
        do {
            return try await context.writingResult { () throws(CommanderError) -> CreativeFile in
                do throws(StateFileStore.Failure) {
                    return try await context.files.update(CreativeFile.self, at: path, message: message) { file in
                        guard var draft = file.draft, draft.revision == revision, change(&draft) else { return false }
                        file.draft = draft
                        file.updatedAt = now
                        return true
                    }.file
                } catch {
                    throw .files(error)
                }
            }
        } catch {
            await report("\(repo) のクリエイティブアセットの記録を書けない（\(error)）。次の見回りでやり直す")
            return nil
        }
    }

    /// 待てば直る失敗の後、GitHub に送らない時刻を決める（上限なら GitHub の示した時間、ほかは読む間隔）
    func holdCreative(_ repo: RepositoryFullName, revision: Int, after error: PullRequestError) {
        var wait = Self.creativeRunCheckInterval
        if case let .rateLimited(retryAfter) = error {
            wait = max(wait, TimeInterval(retryAfter.components.seconds))
        }
        notBefore[Self.creativeKey(repo, revision: revision)] = context.now().addingTimeInterval(wait)
        report("\(repo) のクリエイティブアセットの書き出しを起動できない（\(error)）。\(Int(wait / 60)) 分あけてやり直す")
    }

    /// 今の案を `failed` にする（人は直してほしいことを書いてやり直せる）
    func failCreativeDraft(_ repo: RepositoryFullName, revision: Int, _ message: String, run: WorkflowRunRecord? = nil) async {
        checkedAt[Self.creativeKey(repo, revision: revision)] = nil
        log("\(repo) のクリエイティブアセットの案 \(revision) を進められない（\(message)）")
        await updateCreativeDraft(repo, revision: revision, message: "\(repo) のクリエイティブアセットの案 \(revision) を進められない") { draft in
            guard draft.state == .drafting || draft.state == .rendering else { return false }
            draft.state = .failed
            draft.failure = Self.clamp(message, to: 1000)
            if let run { draft.run = run }
            return true
        }
    }

    /// 書き出しの起動を送り直しても直らない失敗のわけ。待てば直る失敗は nil
    static func lastingCreativeDispatchFailure(_ error: PullRequestError) -> String? {
        if ReleaseWatch.isTransient(error) { return nil }
        return switch error {
        case .notFound:
            "書き出しのワークフロー（\(creativeWorkflow)）が GitHub に無い。app-kit を v1.2.0 以上に広げる"
        case let .rejected(message):
            "書き出しのワークフロー（\(creativeWorkflow)）に断られた（入力が合わない・workflow_dispatch が無いなど。\(message ?? "理由なし")）"
        case .unauthorized, .tokenUnavailable, .forbidden:
            "GitHub のトークンで書き出しのワークフローを起動できない（\(error)）。トークンの Actions の権限を確かめる"
        default:
            "書き出しのワークフロー（\(creativeWorkflow)）を起動できない（\(error)）"
        }
    }

    /// 記録の長さの上限に収める
    static func clamp(_ text: String, to limit: Int) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.unicodeScalars.count > limit else { return trimmed.isEmpty ? "（理由なし）" : trimmed }
        // 長さは Unicode のスカラーで数える（スキーマの maxLength と同じ）。文字の途中で切らない
        var result = ""
        for character in trimmed {
            guard result.unicodeScalars.count + character.unicodeScalars.count < limit else { break }
            result.append(character)
        }
        return result + "…"
    }
}
