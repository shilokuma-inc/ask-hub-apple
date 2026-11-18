import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 配信した後に、release ブランチを main と develop に取り込む（`docs/renewal/release.md` の「リリースを始めてから配信まで」の 10）。
/// 取り込むコミットがあれば司令塔の PR にし、チェックが通ったらマージコミットでマージする（ルールセットを越える直接の push はしない）。
/// main が無ければ、release ブランチの先頭から作る。develop の版（`MARKETING_VERSION`）は、release ブランチで変えていないので上書きしない
extension ReleaseWatch {
    /// 取り込む先（base の develop と main）
    static func integrationBases(_ settings: RepositoryFile) -> [String] {
        let base = settings.build?.baseBranch ?? "develop"
        return base == "main" ? ["main"] : [base, "main"]
    }

    /// 配信した版の release ブランチを、取り込む先ごとに 1 つずつ進める
    func integrate(_ submission: SubmissionFile, settings: RepositoryFile) async -> SubmissionFile {
        var file = submission
        for base in Self.integrationBases(settings) where !(file.integration ?? []).contains(where: { $0.base == base && $0.isDone }) {
            guard !isIntegrationHeld(file) else { break }
            file = await submissionStep(.integration, file) { try await self.integrate($0, into: base, settings: settings) }
        }
        return file
    }

    /// 1 つの取り込む先を進める。変えたら記録を返し、変えることが無ければ nil
    func integrate(_ file: SubmissionFile, into base: String, settings: RepositoryFile) async throws -> SubmissionFile? {
        guard let branch = file.branch?.name else { return nil }
        let current = (file.integration ?? []).first { $0.base == base }
        let next: SubmissionFile.Integration?
        if let current, current.state == .open, let number = current.pullRequest {
            next = try await advanceIntegration(file.repo, current, number: number, settings: settings)
        } else {
            next = try await openIntegration(file.repo, branch: branch, base: base)
        }
        guard let next else { return nil }
        var file = file
        var integration = file.integration ?? []
        integration.removeAll { $0.base == base }
        integration.append(next)
        file.integration = integration
        return file
    }

    /// 取り込むコミットがあれば PR を出す。無ければ取り込まない（`skipped`）。main が無ければ作る（`created`）
    private func openIntegration(_ repo: RepositoryFullName, branch: String, base: String) async throws -> SubmissionFile.Integration {
        guard let head = try await github({ () throws(PullRequestError) in try await hosting.branchHead(repo, branch: branch) }) else {
            throw ReleaseStepProblem("\(branch) が無い（消された）。main と develop への取り込みは人が行う", needsHuman: true)
        }
        guard try await github({ () throws(PullRequestError) in try await hosting.branchHead(repo, branch: base) }) != nil else {
            guard base == "main" else { throw ReleaseStepProblem("\(base) ブランチが無い", needsHuman: true) }
            _ = try await github { () throws(PullRequestError) in try await hosting.createBranch(repo, branch: base, at: head) }
            log("\(repo) に main が無かったので、\(branch)（\(head.prefix(7))）から作った")
            return .init(base: base, state: .created, at: context.timestamp)
        }
        let (ahead, _) = try await github { () throws(PullRequestError) in try await hosting.compare(repo, base: base, head: branch) }
        guard ahead > 0 else { return .init(base: base, state: .skipped, at: context.timestamp) }
        let title = "\(branch) を \(base) に取り込む"
        let body = """
            App Store で配信した \(branch) を、\(base) に取り込みます（\(ahead) コミット）。
            release ブランチでは版（`MARKETING_VERSION`）を変えていないので、\(base) の版はそのまま残ります。

            チェックが通ったら AskHub がマージします。コンフリクトしたときは、人が直してください。
            """
        let pull = try await github { () throws(PullRequestError) in
            try await hosting.openPullRequest(repo, PullRequestDraft(base: base, head: branch, title: "【CHORE】\(title)", body: body))
        }
        log("\(repo) の \(title) PR #\(pull.number) を作った")
        return .init(base: base, state: .open, pullRequest: pull.number, at: context.timestamp)
    }

    /// 開いている取り込みの PR の、チェックを待ってマージする
    private func advanceIntegration(
        _ repo: RepositoryFullName,
        _ current: SubmissionFile.Integration,
        number: Int,
        settings: RepositoryFile
    ) async throws -> SubmissionFile.Integration? {
        var next = current
        let pull = try await github { () throws(PullRequestError) in try await hosting.pullRequest(repo, number: number) }
        if pull.merged {
            next.state = .merged
            next.at = context.timestamp
            return next
        }
        guard pull.state == .open else {
            throw ReleaseStepProblem("取り込みの PR #\(number) が、マージされずに閉じられた。人が \(current.base) に取り込む", needsHuman: true)
        }
        // ビルドの設定が無ければ、すべてのチェックを待つ
        let required = settings.build.map { Set($0.finalChecks) }
        let summary = try await github { () throws(PullRequestError) in
            try await hosting.checks(repo, at: pull.headSHA, required: required)
        }
        switch summary.verdict {
        case .pending, .runnerShortage:
            return nil
        case .failed:
            let names = summary.failures.map(\.name).joined(separator: "・")
            throw ReleaseStepProblem("取り込みの PR #\(number) のチェックが落ちた（\(names)）。人が直す", needsHuman: true)
        case .passed:
            _ = try await github { () throws(PullRequestError) in try await hosting.merge(repo, number: number, headSHA: pull.headSHA) }
            log("\(repo) の取り込みの PR #\(number) をマージした")
            next.state = .merged
            next.at = context.timestamp
            return next
        }
    }

    /// 人が直す取り込みの問題を書いてから、まだ試し直さない（30 分）
    private func isIntegrationHeld(_ file: SubmissionFile) -> Bool {
        guard let problem = file.problem, problem.step == .integration, problem.needsHuman else { return false }
        return context.now().timeIntervalSince(problem.at.date) < 30 * 60
    }
}
