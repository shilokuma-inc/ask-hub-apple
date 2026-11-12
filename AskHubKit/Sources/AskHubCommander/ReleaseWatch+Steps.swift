import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 後作業の段取り（`docs/renewal/release.md` の「後作業の段取り」）。どれも、進めた欄を足した記録を返す（進めることが無ければ nil）。
/// 進められなければ `ReleaseStepProblem` を投げる（`ReleaseWatch.step` が記録の `problem` に書く）
extension ReleaseWatch {
    // MARK: - 1. コミット

    func findCommit(_ file: ReleaseFile) async throws -> ReleaseFile? {
        var file = file
        let tagName = file.version.tagName
        // 人が手で付けたタグがあれば、それが指すコミットを配信したコミットにする
        if let tagged = try await github({ () throws(PullRequestError) in try await hosting.tagCommit(file.repo, tag: tagName) }) {
            file.commit = .init(sha: tagged, source: .existingTag)
            file.tag = .init(name: tagName, created: false, at: context.timestamp)
            return file
        }
        guard let platform = file.platforms.first, let uploadedAt = platform.uploadedAt?.date else {
            throw ReleaseStepProblem("配信したビルドを上げた時刻が分からない。タグ \(tagName) を手で付けると、そのコミットで続ける", needsHuman: true)
        }
        let runs = try await github { () throws(PullRequestError) in
            try await hosting.workflowRuns(
                file.repo,
                createdFrom: uploadedAt.addingTimeInterval(-ReleaseCommitFinder.lookBack),
                to: uploadedAt
            )
        }
        switch ReleaseCommitFinder.find(in: runs, build: platform.build, uploadedAt: uploadedAt) {
        case let .found(run):
            file.commit = .init(
                sha: run.headSHA,
                source: .uploadRun,
                platform: platform.platform,
                build: platform.build,
                run: run.id,
                runNumber: run.runNumber
            )
            return file
        case .notFound:
            throw ReleaseStepProblem(
                "ビルド (\(platform.build)) を上げた Upload の実行（\(ReleaseCommitFinder.uploadWorkflow)）が見つからない。タグ \(tagName) を手で付けると、そのコミットで続ける",
                needsHuman: true
            )
        case let .ambiguous(candidates):
            let list = candidates.map { "実行 \($0.runNumber)（\($0.headSHA.prefix(7))）" }.joined(separator: "・")
            throw ReleaseStepProblem(
                "ビルド (\(platform.build)) を上げた Upload の実行を 1 つに決められない（候補: \(list)）。タグ \(tagName) を手で付けると、そのコミットで続ける",
                needsHuman: true
            )
        }
    }

    // MARK: - 2. タグ

    func tag(_ file: ReleaseFile) async throws -> ReleaseFile? {
        guard let commit = file.commit else { return nil }
        var file = file
        let tagName = file.version.tagName
        if let existing = try await github({ () throws(PullRequestError) in try await hosting.tagCommit(file.repo, tag: tagName) }) {
            guard existing == commit.sha else {
                throw ReleaseStepProblem("タグ \(tagName) が、配信したコミット（\(commit.sha.prefix(7))）と違うコミットを指している", needsHuman: true)
            }
            file.tag = .init(name: tagName, created: false, at: context.timestamp)
            return file
        }
        let build = commit.build ?? file.platforms.first?.build ?? ""
        let name = apps[file.repo]?.app.name ?? file.repo.name
        let message = "\(name) \(file.version) (\(build))\n\nApp Store で配信した \(file.version) のビルド (\(build)) のコミット。\n"
        let tagger = await authors.author(for: file.repo.owner)
        let now = context.now()
        let annotated = AnnotatedTag(name: tagName, commit: commit.sha, message: message, tagger: tagger, date: now)
        try await github { () throws(PullRequestError) in try await hosting.createAnnotatedTag(file.repo, annotated) }
        log("\(file.repo) のコミット \(commit.sha.prefix(7)) にタグ \(tagName) を付けた")
        file.tag = .init(name: tagName, created: true, at: context.timestamp)
        return file
    }

    // MARK: - 3〜5. リリース文と GitHub Release

    func advanceRelease(_ file: ReleaseFile) async throws -> ReleaseFile? {
        guard let tag = file.tag, let commit = file.commit else { return nil }
        var file = file
        if let confirmed = file.notes?.confirmed {
            let published = try await github { () throws(PullRequestError) in
                try await hosting.publishRelease(file.repo, tag: tag.name, body: confirmed.text)
            }
            log("\(file.repo) の GitHub Release \(tag.name) を公開した")
            file.githubRelease = .init(url: published.url.absoluteString, created: true, at: context.timestamp)
            return file
        }
        // 下書きを人が確かめるのを待っている
        guard file.notes == nil else { return nil }
        // 人が手で作った Release があれば、それを記録するだけ
        if let existing = try await github({ () throws(PullRequestError) in try await hosting.release(file.repo, tag: tag.name) }) {
            file.githubRelease = .init(url: existing.url.absoluteString, created: false, at: context.timestamp)
            return file
        }
        let changes: ReleaseChanges
        do {
            changes = try await sources.changes(file.repo, upTo: commit.sha, below: file.version)
        } catch {
            throw ReleaseStepProblem("配信したコミットまでの変更を読めない（\(error)）", needsHuman: false)
        }
        let commits = Set(changes.changes.map(\.commit))
        let epics = try await context.epics(of: file.repo) { epic in epic.merge.map { commits.contains($0.commit) } ?? false }
            .sorted { $0.id < $1.id }
            .map { ReleaseNotesMaterial.Epic(title: $0.title, summary: $0.summary) }
        let material = ReleaseNotesMaterial(
            repo: file.repo,
            appName: apps[file.repo]?.app.name ?? file.repo.name,
            version: file.version,
            commit: commit.sha,
            changes: changes,
            epics: epics
        )
        let draft: String
        do {
            draft = try await drafter.draft(material)
        } catch {
            throw ReleaseStepProblem(error.message, needsHuman: !error.retryable)
        }
        log("\(file.repo) の \(file.version) のリリース文を下書きした。人が確かめるのを待つ")
        file.notes = .init(version: 1, previousTag: changes.previousTag, draft: draft, draftedAt: context.timestamp)
        return file
    }

    // MARK: - 6. 次の版

    func advanceNextVersion(_ file: ReleaseFile, settings: RepositoryFile) async throws -> ReleaseFile? {
        var file = file
        let base = settings.build?.baseBranch ?? "develop"
        guard let next = file.nextVersion else {
            file.nextVersion = try await openNextVersion(file, base: base)
            return file
        }
        guard next.state == .open, let number = next.pullRequest else { return nil }
        let pull = try await github { () throws(PullRequestError) in try await hosting.pullRequest(file.repo, number: number) }
        if pull.merged {
            file.nextVersion?.state = .merged
            file.nextVersion?.at = context.timestamp
            return file
        }
        guard pull.state == .open else {
            throw ReleaseStepProblem("版を上げる PR #\(number) が、マージされずに閉じられた。人が develop の MARKETING_VERSION を上げる", needsHuman: true)
        }
        let required = Set(settings.build?.finalChecks ?? [])
        let summary = try await github { () throws(PullRequestError) in
            try await hosting.checks(file.repo, at: pull.headSHA, required: required)
        }
        switch summary.verdict {
        case .pending, .runnerShortage:
            return nil
        case .failed:
            let names = summary.failures.map(\.name).joined(separator: "・")
            throw ReleaseStepProblem("版を上げる PR #\(number) のチェックが落ちた（\(names)）。人が直す", needsHuman: true)
        case .passed:
            _ = try await github { () throws(PullRequestError) in
                try await hosting.merge(file.repo, number: number, headSHA: pull.headSHA)
            }
            log("\(file.repo) の版を上げる PR #\(number) をマージした")
            file.nextVersion?.state = .merged
            file.nextVersion?.at = context.timestamp
            return file
        }
    }

    /// develop の版がもう大きければ上げない。そうでなければ、版を上げるコミットのブランチと PR を作る
    func openNextVersion(_ file: ReleaseFile, base: String) async throws -> ReleaseFile.NextVersion {
        let snapshot: MarketingVersionSnapshot
        do {
            snapshot = try await sources.marketingVersions(file.repo, base: base)
        } catch {
            throw ReleaseStepProblem("\(base) の MARKETING_VERSION を読めない（\(error)）", needsHuman: false)
        }
        guard let current = snapshot.current else {
            throw ReleaseStepProblem("\(base) のビルドの設定に MARKETING_VERSION が見つからない。人が次の版に上げる", needsHuman: true)
        }
        if current > file.version {
            log("\(file.repo) の \(base) の版（\(current)）は配信した \(file.version) より大きいので、上げない")
            return .init(version: current, state: .skipped, at: context.timestamp)
        }
        let next = file.version.nextMinor
        var files: [String: String] = [:]
        for source in snapshot.files {
            if let edited = MarketingVersionEdit.replacing(in: source.content, atMost: file.version, with: next) {
                files[source.path] = edited
            }
        }
        let branch = "askhub/version-\(next)"
        let author = await authors.author(for: file.repo.owner)
        let now = context.now()
        let title = "MARKETING_VERSION を \(next) に上げる"
        let message = "[chore] \(title)"
        let commit = VersionCommit(files: files, snapshot: snapshot, message: message, author: author, date: now, branch: branch)
        _ = try await github { () throws(PullRequestError) in try await hosting.commitFiles(file.repo, commit) }
        let body = """
            App Store で \(file.version) の配信を見つけたので、\(base) の `MARKETING_VERSION` を次の版（\(next)）に上げます。
            配信済みの版のままだと、\(base) の Upload が App Store Connect に断られるためです。

            チェックが通ったら AskHub がマージします。大きく上げたい（2.0.0 など）ときは、この PR を閉じて手で上げてください。
            """
        let pull = try await github { () throws(PullRequestError) in
            try await hosting.openPullRequest(file.repo, PullRequestDraft(base: base, head: branch, title: "【CHORE】\(title)", body: body))
        }
        log("\(file.repo) の版を \(next) に上げる PR #\(pull.number) を作った")
        return .init(version: next, state: .open, pullRequest: pull.number, at: context.timestamp)
    }

    // MARK: - 共通

    /// GitHub の操作。待てば直る失敗はそのまま投げ（次の見回りでやり直す）、人が直す失敗は `ReleaseStepProblem` にする
    func github<Value>(_ body: () async throws(PullRequestError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            switch error {
            case .rateLimited, .serverError, .transport, .cancelled, .malformed, .headChanged:
                throw ReleaseStepProblem("GitHub に届かない（\(error)）", needsHuman: false)
            case .unauthorized, .tokenUnavailable, .forbidden:
                throw ReleaseStepProblem("GitHub のトークンで操作できない（\(error)）", needsHuman: true)
            default:
                throw ReleaseStepProblem("GitHub に断られた（\(error)）", needsHuman: true)
            }
        }
    }
}

/// 後作業の段取りを進められない理由
struct ReleaseStepProblem: Error {
    var message: String
    /// 人が直す必要がある（やり直しても進まない）
    var needsHuman: Bool

    init(_ message: String, needsHuman: Bool) {
        self.message = message
        self.needsHuman = needsHuman
    }
}
