import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 出した PR を追う（待つチェックが通ったらマージし、試しの 1 本はマージした後の develop の Build を待つ）
extension AppKitRolloutDriver {
    // MARK: - 出した PR を追う

    func follow(_ target: AppKitFile.Target, release: AppKitRelease, rollout: AppKitFile.Rollout) async -> Step {
        let now = context.timestamp
        var failed = target
        failed.state = .failed
        failed.updatedAt = now
        let github: GitHubPullRequests
        switch await admin.pullRequests(for: target.repo, now: context.now()) {
        case let .success(made): github = made
        case let .failure(refusal):
            // 上限で待っているだけなら、次の印でもう一度見る
            if case .rateLimited = refusal { return Step(target: target) }
            failed.problem = refusal.description
            return Step(target: failed)
        }
        do throws(PullRequestError) {
            if target.state == .verifying { return try await verify(target, rollout: rollout, github: github) }
            return try await mergeIfReady(target, release: release, rollout: rollout, github: github)
        } catch {
            await admin.note(error, owner: target.repo.owner, now: context.now())
            if case .rateLimited = error { return Step(target: target) }
            if case .notMergeable = error {
                failed.problem = "PR #\(target.pullRequest ?? 0) をマージできない（コンフリクト・必須のチェックなど。GitHub: \(error)）"
                return Step(target: failed)
            }
            log("\(target.repo) の app-kit の PR を確かめられない（\(error)）。次の生きている印でもう一度見る")
            return Step(target: target)
        }
    }

    private func mergeIfReady(
        _ target: AppKitFile.Target,
        release: AppKitRelease,
        rollout: AppKitFile.Rollout,
        github: GitHubPullRequests
    ) async throws(PullRequestError) -> Step {
        let now = context.timestamp
        var next = target
        next.updatedAt = now
        guard let number = target.pullRequest else {
            next.state = .failed
            next.problem = "PR の番号が無い"
            return Step(target: next)
        }
        let pullRequest = try await github.pullRequest(number: number)
        if pullRequest.merged {
            return merged(target, commit: pullRequest.mergeCommitSHA, rollout: rollout)
        }
        guard pullRequest.state == .open else {
            next.state = .failed
            next.problem = "PR #\(number) がマージされずに閉じられた"
            return Step(target: next)
        }
        // 人が直しを push したなど、head が変わっても、写すファイルのほかが変わっていなければ続ける
        let outside = try await github.pullRequestFiles(number: number).filter { !release.manifest.managed.contains($0) }
        if !outside.isEmpty {
            next.state = .failed
            next.problem = "PR #\(number) で写すファイルのほか（\(outside.prefix(5).joined(separator: "・"))）が変わっているので、マージしない"
            return Step(target: next)
        }
        if pullRequest.headSHA != target.head { next.head = pullRequest.headSHA }
        let checks = try await requiredChecks(for: target)
        let summary = try await github.checks(at: pullRequest.headSHA, policy: CheckPolicy(required: Set(checks)))
        switch summary.verdict {
        case .passed:
            let merge = try await github.merge(number: number, headSHA: pullRequest.headSHA)
            log("\(target.repo) の app-kit \(rollout.version) の PR #\(number) をマージした")
            return merged(next, commit: merge.sha, rollout: rollout)
        case .failed:
            next.state = .failed
            next.problem = "PR #\(number) の待つチェック（\(summary.failures.map(\.name).joined(separator: "・"))）が落ちた"
            return Step(target: next)
        case .pending, .runnerShortage:
            let waited = context.now().timeIntervalSince(target.updatedAt.date)
            if !summary.missing.isEmpty, waited >= checksTimeout {
                next.state = .failed
                next.problem = "PR #\(number) を出して 30 分たっても、待つチェック（\(summary.missing.joined(separator: "・"))）が出ない"
                return Step(target: next)
            }
            return Step(target: next.head == target.head ? target : next)
        }
    }

    /// マージした。試しの 1 本は develop の Build を待ち、ほかは入れたことにする
    private func merged(_ target: AppKitFile.Target, commit: String?, rollout: AppKitFile.Rollout) -> Step {
        var next = target
        next.updatedAt = context.timestamp
        if target.repo == rollout.pilot, let commit, AttemptFile.isCommitSHA(commit) {
            next.state = .verifying
            next.mergeCommit = commit
            return Step(target: next)
        }
        next.state = .done
        next.mergeCommit = commit.flatMap { AttemptFile.isCommitSHA($0) ? $0 : nil }
        return Step(target: next, installed: true)
    }

    /// 試しの 1 本のマージした後の develop の Build（Archive・Upload を変えた版なら Upload も）を待つ
    private func verify(
        _ target: AppKitFile.Target,
        rollout: AppKitFile.Rollout,
        github: GitHubPullRequests
    ) async throws(PullRequestError) -> Step {
        var next = target
        next.updatedAt = context.timestamp
        guard let commit = target.mergeCommit else {
            next.state = .failed
            next.problem = "マージしたコミットが分からない"
            return Step(target: next)
        }
        let build = try await github.checks(at: commit, policy: CheckPolicy(required: Set(ProtectionPolicy.defaultRequiredChecks)))
        var verdict = build.verdict
        var failures = build.failures.map(\.name)
        if verdict == .passed, await archiveChanged(for: target, rollout: rollout) {
            let uploads = try await github.checkRuns(at: commit).filter {
                $0.app == "github-actions" && $0.name.lowercased().hasPrefix("upload")
            }
            verdict = Self.uploadVerdict(uploads)
            failures = uploads.filter { $0.conclusion.map { !Self.passing.contains($0) } ?? false }.map(\.name)
        }
        switch verdict {
        case .passed:
            next.state = .done
            log("試しの 1 本 \(target.repo) の app-kit \(rollout.version) の develop の Build が通った")
            return Step(target: next, installed: true)
        case .failed:
            next.state = .failed
            next.problem = "試しの 1 本のマージした後の develop（\(commit.prefix(7))）の \(failures.joined(separator: "・")) が落ちた"
            return Step(target: next)
        case .pending, .runnerShortage:
            if context.now().timeIntervalSince(target.updatedAt.date) >= verifyTimeout {
                next.state = .failed
                next.problem = "試しの 1 本をマージして 90 分たっても、develop（\(commit.prefix(7))）の Build が終わらない"
                return Step(target: next)
            }
            return Step(target: target)
        }
    }

    static let passing: Set<String> = ["success", "neutral", "skipped"]

    /// Upload の check run の様子（飛ばしたもの（`ENABLE_DELIVERY=false`）は通ったものとみなす）。まだ出ていなければ待つ
    static func uploadVerdict(_ runs: [CheckRunStatus]) -> CheckSummary.Verdict {
        guard !runs.isEmpty else { return .pending }
        if runs.contains(where: { $0.conclusion.map { !passing.contains($0) } ?? false }) { return .failed }
        return runs.allSatisfy { $0.status == "completed" } ? .passed : .pending
    }

    /// 前の版からこの版で、Archive・Upload の再利用ワークフローか、その道具が変わったか。読めなければ変わったとみなす
    private func archiveChanged(for target: AppKitFile.Target, rollout: AppKitFile.Rollout) async -> Bool {
        guard let previous = try? await installed(target)?.ref, previous != rollout.ref else { return false }
        guard let paths = try? await source.changedPaths(from: previous, to: rollout.ref) else { return true }
        return paths.contains(where: Self.isArchivePath)
    }

    /// Archive・Upload の再利用ワークフローか、その道具
    static func isArchivePath(_ path: String) -> Bool {
        path == ".github/workflows/app-archive.yml" || path.hasPrefix("tools/app-store-connect/")
            || path.hasSuffix("entitlements.sh") || path.hasSuffix("signatures.sh")
    }

    func installed(_ target: AppKitFile.Target) async throws(CommanderError) -> RepositoryFile.AppKit? {
        switch target.kind {
        case .repository: try await context.readable(RepositoryFile.self, at: StatePath.repository(target.repo))?.appKit
        case .template:
            try await context.readable(AppKitFile.self, at: StatePath.appKit)?.templates.first { $0.repo == target.repo }?.appKit
        }
    }

    private func requiredChecks(for target: AppKitFile.Target) async throws(PullRequestError) -> [String] {
        guard target.kind == .repository,
              let repository = try? await context.readable(RepositoryFile.self, at: StatePath.repository(target.repo)) else {
            return ProtectionPolicy.defaultRequiredChecks
        }
        return Self.requiredChecks(of: repository)
    }
}
