import AskHubProtocol
import AskHubPullRequests
import Foundation

/// リポジトリの撮影のワークフローで撮る App Store のスクショ（`capture: actions`。`docs/renewal/store-screenshots.md` の「撮影の起動と見張り」）。
///
/// release ブランチの先頭を読み、撮り始めた印（`run.dispatchedAt`）を書いてから、ワークフローを `upload: false` で起動する。
/// 送った後に落ちて実行の id を書けなかったときは、ブランチの `workflow_dispatch` の実行の一覧から探し、5 分たっても無ければ送り直す。
/// 見回りの周で実行を読み（5 分空ける）、様子が変わったときだけ書く。人が直す失敗（ワークフローが無い・入力が合わない・トークン・
/// 取り消された・6 時間で終わらない）は `failed` にし、スクショを変えずに審査に出せるようにする
extension ReleaseWatch {
    /// 実行を読む間隔
    static let screenshotRunCheckInterval: TimeInterval = 5 * 60
    /// 実行の id が分からないまま、起動を送り直すまでの時間
    static let screenshotRedispatchAfter: TimeInterval = 5 * 60
    /// 撮り始めてから打ち切るまでの時間（template のワークフローは表示サイズを 1 本ずつ撮り、各ジョブの上限は 90 分）
    static let screenshotRunTimeout: TimeInterval = 6 * 60 * 60

    /// 撮影を進める（起動 → 見張り）。撮り終えたら結果を書く
    func advanceScreenshotWorkflow(_ file: SubmissionFile, workflow: StoreScreenshotWorkflow) async -> SubmissionFile {
        guard let branch = file.branch else { return file }
        let key = Self.screenshotKey(file)
        guard let current = file.screenshots, current.state == .capturing, let run = current.run else {
            guard file.screenshots == nil || file.screenshots?.state == .capturing else { return file }
            return await startScreenshotWorkflow(file, workflow: workflow, branch: branch)
        }
        if let checked = screenshotRunsCheckedAt[key], context.now().timeIntervalSince(checked) < Self.screenshotRunCheckInterval {
            return file
        }
        screenshotRunsCheckedAt[key] = context.now()
        let advanced: SubmissionFile
        if run.id == nil {
            advanced = await findScreenshotRun(file, workflow: workflow, branch: branch, run: run)
        } else {
            advanced = await watchScreenshotRun(file, run: run)
        }
        if advanced.screenshots?.state.isSettled == true { screenshotRunsCheckedAt[key] = nil }
        return advanced
    }

    /// release ブランチの先頭を読み、撮り始めた印を書いてから起動する
    private func startScreenshotWorkflow(
        _ file: SubmissionFile,
        workflow: StoreScreenshotWorkflow,
        branch: SubmissionFile.Branch
    ) async -> SubmissionFile {
        let now = context.timestamp
        let started = await submissionStep(.screenshots, file) { file in
            let head = try await self.github { () throws(PullRequestError) in
                try await self.hosting.branchHead(file.repo, branch: branch.name)
            }
            guard let head, ReleaseFile.isCommit(head) else {
                throw ReleaseStepProblem("\(branch.name) が無い。リリースをやめて始め直す", needsHuman: true)
            }
            var file = file
            let startedAt = file.screenshots?.startedAt ?? now
            file.screenshots = .init(state: .capturing, commit: head, startedAt: startedAt, run: .init(dispatchedAt: now))
            return file
        }
        guard let marked = started.screenshots, marked.state == .capturing, let run = marked.run, run.id == nil,
              run.dispatchedAt == now else { return started }
        return await dispatchScreenshotWorkflow(started, workflow: workflow, branch: branch)
    }

    /// ワークフローを起動し、実行の id を書く。古い形の応答（id なし）なら、次の見回りで一覧から探す
    private func dispatchScreenshotWorkflow(
        _ file: SubmissionFile,
        workflow: StoreScreenshotWorkflow,
        branch: SubmissionFile.Branch
    ) async -> SubmissionFile {
        screenshotRunsCheckedAt[Self.screenshotKey(file)] = context.now()
        let inputs = Self.screenshotInputs(workflow)
        return await submissionStep(.screenshots, file) { file in
            let dispatched: DispatchedRun?
            do throws(PullRequestError) {
                dispatched = try await self.hosting.dispatchWorkflow(
                    file.repo, workflow: workflow.workflow, ref: branch.name, inputs: inputs
                )
            } catch {
                guard let reason = Self.lastingDispatchFailure(error, workflow: workflow.workflow) else {
                    throw ReleaseStepProblem("撮影のワークフローを起動できない（\(error)）。次の見回りでやり直す", needsHuman: false)
                }
                return Self.failedScreenshots(file, reason, at: self.context.timestamp)
            }
            let which = dispatched.map { "実行 \($0.id)" } ?? "実行の id は次の見回りで探す"
            self.log("\(file.repo) の \(file.version) のスクショの撮影（\(workflow.workflow)）を \(branch.name) で起動した（\(which)）")
            guard let dispatched, var screenshots = file.screenshots, var run = screenshots.run else { return nil }
            run.id = dispatched.id
            run.url = dispatched.url?.absoluteString
            screenshots.run = run
            var file = file
            file.screenshots = screenshots
            return file
        }
    }

    /// 起動した後に id を書けなかった実行を、ブランチの `workflow_dispatch` の実行から探す。見つからないまま 5 分たてば送り直す
    private func findScreenshotRun(
        _ file: SubmissionFile,
        workflow: StoreScreenshotWorkflow,
        branch: SubmissionFile.Branch,
        run: SubmissionFile.CaptureRun
    ) async -> SubmissionFile {
        let now = context.timestamp
        let found = await submissionStep(.screenshots, file) { file in
            let runs = try await self.github { () throws(PullRequestError) in
                try await self.hosting.dispatchedRuns(file.repo, workflow: workflow.workflow, branch: branch.name)
            }
            var file = file
            if let found = Self.dispatchedRun(in: runs, workflow: workflow.workflow, branch: branch.name, since: run.dispatchedAt.date) {
                file.screenshots?.run = Self.record(found, dispatchedAt: run.dispatchedAt)
                if ReleaseFile.isCommit(found.headSHA) { file.screenshots?.commit = found.headSHA }
                return file
            }
            guard self.context.now().timeIntervalSince(run.dispatchedAt.date) >= Self.screenshotRedispatchAfter else { return nil }
            // 送り直す。先に送った時刻を書き直す（ここで落ちても、また一覧から探してから送る）
            file.screenshots?.run = .init(dispatchedAt: now)
            return file
        }
        guard let marked = found.screenshots?.run, marked.id == nil, marked.dispatchedAt == now else { return found }
        return await dispatchScreenshotWorkflow(found, workflow: workflow, branch: branch)
    }

    /// 実行を読み、様子が変わったら書く。終わったら結果を書き、6 時間で終わらなければ取り消して `failed` にする
    private func watchScreenshotRun(_ file: SubmissionFile, run: SubmissionFile.CaptureRun) async -> SubmissionFile {
        guard let id = run.id, let startedAt = file.screenshots?.startedAt else { return file }
        return await submissionStep(.screenshots, file) { file in
            let detail = try await self.github { () throws(PullRequestError) in try await self.hosting.workflowRun(file.repo, id: id) }
            let original = file
            var file = file
            let updated = Self.record(detail, dispatchedAt: run.dispatchedAt, previous: run)
            if ReleaseFile.isCommit(detail.headSHA) { file.screenshots?.commit = detail.headSHA }
            file.screenshots?.run = updated
            let now = self.context.timestamp
            if !detail.isCompleted {
                guard now.date.timeIntervalSince(startedAt.date) >= Self.screenshotRunTimeout else {
                    // 様子が変わらなければ書かない（書き込みの予算のため）
                    return file.screenshots == original.screenshots ? nil : file
                }
                let hours = Int(Self.screenshotRunTimeout / 3600)
                do throws(PullRequestError) {
                    try await self.hosting.cancelWorkflowRun(file.repo, id: id)
                } catch .conflict {
                    // 読んだ後に終わった（終わった実行は取り消せない）。次の見回りで終わった実行として読む
                    return file.screenshots == original.screenshots ? nil : file
                } catch {
                    // 待てば直る失敗は、撮っている印のまま次の見回りで取り消し直す（実行を動かしたまま終えない）
                    guard !Self.isTransient(error) else {
                        throw ReleaseStepProblem("撮影の実行 \(id) を取り消せない（\(error)）。次の見回りでやり直す", needsHuman: false)
                    }
                    return Self.failedScreenshots(
                        file, "撮影の実行 \(id) が \(hours) 時間で終わらないが、取り消せない（\(error)）。GitHub で取り消す", at: now
                    )
                }
                return Self.failedScreenshots(file, "撮影の実行 \(id) が \(hours) 時間で終わらないので取り消した", at: now)
            }
            self.log("\(file.repo) の \(file.version) のスクショの撮影（実行 \(id)）が終わった（\(detail.conclusion ?? "結論なし")）")
            return await self.settleScreenshotRun(file, detail: detail)
        }
    }

    /// 終わった実行の結果を決める。取り込み（artifact と比べ方）は次の段階（#1192 の PR (b)）で作るので、今は撮れた実行も `failed` にする
    func settleScreenshotRun(_ file: SubmissionFile, detail: WorkflowRunDetail) async -> SubmissionFile {
        let now = context.timestamp
        switch detail.conclusion {
        case "success", "failure":
            return Self.failedScreenshots(
                file, "撮影の実行 \(detail.id) は終わった（\(detail.conclusion ?? "")）が、artifact の取り込みはまだ作っていないので、スクショは変えない", at: now
            )
        default:
            return Self.failedScreenshots(file, "撮影の実行 \(detail.id) が \(detail.conclusion ?? "結論なし") で終わった。撮り直す", at: now)
        }
    }

    /// 撮影のワークフローの入力（反映はしない。撮る表示サイズは `artifacts` の値）
    static func screenshotInputs(_ workflow: StoreScreenshotWorkflow) -> [String: String] {
        ["upload": "false", "display_types": Set(workflow.artifacts.values).sorted().joined(separator: ",")]
    }

    /// 待てば直る失敗（上限・GitHub の障害・届かない）
    static func isTransient(_ error: PullRequestError) -> Bool {
        switch error {
        case .rateLimited, .serverError, .transport, .cancelled, .malformed: true
        default: false
        }
    }

    /// 起動を送り直しても直らない失敗のわけ。待てば直る失敗は nil
    static func lastingDispatchFailure(_ error: PullRequestError, workflow: String) -> String? {
        if isTransient(error) { return nil }
        return switch error {
        case .notFound:
            "撮影のワークフロー（\(workflow)）が GitHub に無い（登録されていない・名前が違う）。直してから撮り直す"
        case let .rejected(message):
            "撮影のワークフロー（\(workflow)）に断られた（入力が合わない・workflow_dispatch が無いなど。\(message ?? "理由なし")）"
        case .unauthorized, .tokenUnavailable, .forbidden:
            "GitHub のトークンで撮影のワークフローを起動できない（\(error)）。トークンの Actions の権限を確かめる"
        default:
            "撮影のワークフロー（\(workflow)）を起動できない（\(error)）"
        }
    }

    /// ブランチで起動した、そのワークフローの実行のうち、作られた時刻が起動を送った時刻に最も近いもの（1 分前〜10 分後。時計のずれと、
    /// 実行が一覧に出るまでの遅れを許す）。最も古いものを選ぶと、起動の直前に人が起動した実行を取り違えるので、送った時刻との近さで選ぶ
    static func dispatchedRun(in runs: [WorkflowRunDetail], workflow: String, branch: String, since: Date) -> WorkflowRunDetail? {
        let path = ".github/workflows/\(workflow)"
        return runs.filter { run in
            // 呼び出されたワークフローなどでは path が <ファイル>@<ref> になる
            let file = run.path.split(separator: "@", maxSplits: 1).first.map(String.init) ?? run.path
            let offset = run.createdAt.timeIntervalSince(since)
            return run.event == "workflow_dispatch" && file == path && run.headBranch == branch && (-60...600).contains(offset)
        }
        .min { abs($0.createdAt.timeIntervalSince(since)) < abs($1.createdAt.timeIntervalSince(since)) }
    }

    /// 実行の様子を記録の形にする（URL は前に書いたものを残す）
    static func record(
        _ detail: WorkflowRunDetail,
        dispatchedAt: Timestamp,
        previous: SubmissionFile.CaptureRun? = nil
    ) -> SubmissionFile.CaptureRun {
        .init(
            id: detail.id,
            url: detail.url?.absoluteString ?? previous?.url,
            dispatchedAt: dispatchedAt,
            status: Self.word(detail.status),
            conclusion: detail.conclusion.flatMap(Self.word)
        )
    }

    /// GitHub の様子の語（記録の形に合わないものは書かない）
    private static func word(_ text: String) -> String? {
        text.wholeMatch(of: #/[a-z_]{1,40}/#) == nil ? nil : text
    }

    /// 撮れなかった結果（撮り始めた印のコミット・時刻と実行を残す）
    static func failedScreenshots(_ file: SubmissionFile, _ message: String, at now: Timestamp) -> SubmissionFile {
        var file = file
        let current = file.screenshots
        file.screenshots = .init(
            state: .failed,
            commit: current?.commit,
            startedAt: current?.startedAt ?? now,
            finishedAt: now,
            failure: message,
            run: current?.run
        )
        return file
    }
}
