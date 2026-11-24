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
        let run: ActionsRun
        switch ReleaseCommitFinder.find(in: runs, build: platform.build, uploadedAt: uploadedAt) {
        case let .found(found):
            run = found
        case .notFound:
            throw ReleaseStepProblem(
                "ビルド (\(platform.build)) を上げた Upload の実行（\(ReleaseCommitFinder.uploadWorkflow)）が見つからない。タグ \(tagName) を手で付けると、そのコミットで続ける",
                needsHuman: true
            )
        case let .ambiguous(candidates):
            // 同じ時刻に違うコミットの Upload が流れた（develop と release/** が同時に動いたなど）。job のログのビルドの番号で確かめる
            if let confirmed = try await runShowingBuild(file.repo, candidates: candidates, build: platform.build) {
                log("\(file.repo) のビルド (\(platform.build)) を上げた Upload の実行を、job のログのビルドの番号で実行 \(confirmed.runNumber) に決めた")
                run = confirmed
                break
            }
            let list = candidates.map { "実行 \($0.runNumber)（\($0.headSHA.prefix(7))）" }.joined(separator: "・")
            let logs = candidates.count <= ReleaseCommitFinder.maximumRunsToRead
                ? "。job のログのビルドの番号でも絞れない" : "。候補が多いので job のログは読まない"
            throw ReleaseStepProblem(
                "ビルド (\(platform.build)) を上げた Upload の実行を 1 つに決められない（候補: \(list)\(logs)）。タグ \(tagName) を手で付けると、そのコミットで続ける",
                needsHuman: true
            )
        }
        file.commit = .init(
            sha: run.headSHA,
            source: .uploadRun,
            platform: platform.platform,
            build: platform.build,
            run: run.id,
            runNumber: run.runNumber
        )
        return file
    }

    /// 候補の Upload の実行のうち、job のログにビルドの番号を書いたもの（`ReleaseCommitFinder.logShowsBuild`）から決める。決まらなければ nil。
    /// REST の上限を考え、読むのは `find` で決まらなかったときだけにし、候補が `maximumRunsToRead` を超えれば読まない。
    /// 1 つの候補で読むのは、job の一覧と、ビルドの番号が見つかるまでの job のログ
    func runShowingBuild(_ repo: RepositoryFullName, candidates: [ActionsRun], build: String) async throws -> ActionsRun? {
        guard candidates.count <= ReleaseCommitFinder.maximumRunsToRead else { return nil }
        var confirmed: [ActionsRun] = []
        for run in candidates {
            let jobs = try await github { () throws(PullRequestError) in try await hosting.runJobs(repo, runID: run.id) }
            // 飛ばした job にはログが無い
            for job in jobs where job.conclusion != "skipped" {
                let log = try await github { () throws(PullRequestError) -> String? in
                    do throws(PullRequestError) {
                        return try await hosting.jobLogHead(repo, jobID: job.id)
                    } catch .notFound, .unexpected(status: 410, message: _) {
                        // 保存の期限を過ぎて消えたログ
                        return nil
                    }
                }
                if let log, ReleaseCommitFinder.logShowsBuild(log, build: build) {
                    confirmed.append(run)
                    break
                }
            }
        }
        return ReleaseCommitFinder.pick(confirmed: confirmed)
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
        // AskHub で審査に出した版は、そのときに人が確かめた What's New で、確かめ直さずに公開する（2026-11-18 にユーザーが決めた）
        if let published = try await publishWithWhatsNew(file, tag: tag) { return published }
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

    /// 審査に出したときの What's New で GitHub Release を公開し、確かめた本文として記録する。AskHub で審査に出していなければ nil
    func publishWithWhatsNew(_ file: ReleaseFile, tag: ReleaseFile.Tag) async throws -> ReleaseFile? {
        guard let whatsNew = await confirmedWhatsNew(file.repo, version: file.version) else { return nil }
        let published = try await github { () throws(PullRequestError) in
            try await hosting.publishRelease(file.repo, tag: tag.name, body: whatsNew.text)
        }
        log("\(file.repo) の GitHub Release \(tag.name) を、審査に出したときの What's New で公開した")
        var file = file
        let confirmed = ReleaseFile.ConfirmedNotes(text: whatsNew.text, approval: whatsNew.approval, at: context.timestamp)
        file.notes = .init(version: 1, draft: whatsNew.text, draftedAt: context.timestamp, confirmed: confirmed)
        file.githubRelease = .init(url: published.url.absoluteString, created: true, at: context.timestamp)
        return file
    }

    // MARK: - 6. 次の版

    func advanceNextVersion(_ file: ReleaseFile, settings: RepositoryFile) async throws -> ReleaseFile? {
        let reason = "App Store で \(file.version) の配信を見つけたので"
        let next = try await nextVersionStep(
            file.repo, version: file.version, current: file.nextVersion, settings: settings, reason: reason
        )
        guard let next else { return nil }
        var file = file
        file.nextVersion = next
        return file
    }

    /// develop の版を `version` の次に上げる PR を進める（配信の後作業と、リリースを始めた版の準備で使う）。
    /// 変えたら新しい様子を返し、変えることが無ければ nil。`reason` は PR の本文の書き出し（「〜ので」）
    func nextVersionStep(
        _ repo: RepositoryFullName,
        version: MarketingVersion,
        current: ReleaseFile.NextVersion?,
        settings: RepositoryFile,
        reason: String,
        hotfix: (base: String, next: MarketingVersion)? = nil
    ) async throws -> ReleaseFile.NextVersion? {
        let base = hotfix?.base ?? settings.build?.baseBranch ?? "develop"
        guard var next = current else {
            return try await openNextVersion(repo, version: version, base: base, reason: reason, next: hotfix?.next)
        }
        guard next.state == .open, let number = next.pullRequest else { return nil }
        let pull = try await github { () throws(PullRequestError) in try await hosting.pullRequest(repo, number: number) }
        if pull.merged {
            next.state = .merged
            next.at = context.timestamp
            return next
        }
        guard pull.state == .open else {
            throw ReleaseStepProblem("版を上げる PR #\(number) が、マージされずに閉じられた。人が \(base) の MARKETING_VERSION を上げる", needsHuman: true)
        }
        // ビルドの設定が無ければ、すべてのチェックを待つ（空の集合は「何も待たない」になり、CI を待たずにマージしてしまう）
        let required = settings.build.map { Set($0.finalChecks) }
        let summary = try await github { () throws(PullRequestError) in
            try await hosting.checks(repo, at: pull.headSHA, required: required)
        }
        switch summary.verdict {
        case .pending, .runnerShortage:
            return nil
        case .failed:
            let names = summary.failures.map(\.name).joined(separator: "・")
            throw ReleaseStepProblem("版を上げる PR #\(number) のチェックが落ちた（\(names)）。人が直す", needsHuman: true)
        case .passed:
            _ = try await github { () throws(PullRequestError) in
                try await hosting.merge(repo, number: number, headSHA: pull.headSHA)
            }
            log("\(repo) の版を上げる PR #\(number) をマージした")
            next.state = .merged
            next.at = context.timestamp
            return next
        }
    }

    /// develop の版がもう大きければ上げない。そうでなければ、版を上げるコミットのブランチと PR を作る。
    /// `next` は hotfix の版（release ブランチの `version` の行を `next` に上げる）。nil なら次のマイナー
    func openNextVersion(
        _ repo: RepositoryFullName,
        version: MarketingVersion,
        base: String,
        reason: String,
        next hotfix: MarketingVersion? = nil
    ) async throws -> ReleaseFile.NextVersion {
        let snapshot: MarketingVersionSnapshot
        do {
            snapshot = try await sources.marketingVersions(repo, base: base)
        } catch {
            throw ReleaseStepProblem("\(base) の MARKETING_VERSION を読めない（\(error)）", needsHuman: false)
        }
        guard let current = snapshot.current else {
            throw ReleaseStepProblem("\(base) のビルドの設定に MARKETING_VERSION が見つからない。人が次の版に上げる", needsHuman: true)
        }
        if current > version {
            log("\(repo) の \(base) の版（\(current)）は \(version) より大きいので、上げない")
            return .init(version: current, state: .skipped, at: context.timestamp)
        }
        let next = hotfix ?? version.nextMinor
        var files: [String: String] = [:]
        for source in snapshot.files {
            if let edited = MarketingVersionEdit.replacing(in: source.content, atMost: version, with: next) {
                files[source.path] = edited
            }
        }
        // hotfix の版を上げるブランチは、develop の版を上げるブランチと名前を分ける
        let branch = hotfix == nil ? "askhub/version-\(next)" : "askhub/hotfix-version-\(next)"
        let author = await authors.author(for: repo.owner)
        let now = context.now()
        let title = "MARKETING_VERSION を \(next) に上げる"
        let message = "[chore] \(title)"
        let commit = VersionCommit(files: files, snapshot: snapshot, message: message, author: author, date: now, branch: branch)
        _ = try await github { () throws(PullRequestError) in try await hosting.commitFiles(repo, commit) }
        let body = hotfix == nil ? """
            \(reason)、\(base) の `MARKETING_VERSION` を次の版（\(next)）に上げます。
            \(version) のままだと、\(base) の Upload が \(version) のビルドを上げ続けるためです（配信した後は App Store Connect に断られます）。

            チェックが通ったら AskHub がマージします。大きく上げたい（2.0.0 など）ときは、この PR を閉じて手で上げてください。
            """ : """
            \(reason)、hotfix の release ブランチ \(base) の `MARKETING_VERSION` を \(next) に上げます。
            配信中の版（\(version)）のタグから作ったので、上げないと Upload が \(version) のビルドを上げようとして App Store Connect に断られます。

            チェックが通ったら AskHub がマージします。
            """
        let pull = try await github { () throws(PullRequestError) in
            try await hosting.openPullRequest(repo, PullRequestDraft(base: base, head: branch, title: "【CHORE】\(title)", body: body))
        }
        log("\(repo) の版を \(next) に上げる PR #\(pull.number) を作った")
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
