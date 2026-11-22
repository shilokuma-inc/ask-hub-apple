import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 人が「広げる」（`rolloutAppKit`）を押した版を、試しの 1 本 → 残りの対象 → 入れ替え済みのテンプレートの順に広げる
/// （`docs/renewal/app-kit.md` の「版を広げる」）。
///
/// 署名した人の意図を続けて進めるものなので、管理用のトークンで PR を出してマージする。1 回に進めるのは 1 つの相手の 1 歩だけ
/// （PR は一度に 1 本。GitHub の上限と司令塔の書き込みの予算を食わないように）。生きている印を書くたびに `advance()` を呼ぶ
struct AppKitRolloutDriver {
    var context: CommanderContext
    var admin: AdminGitHub
    var source: any AppKitSource
    var log: @Sendable (String) -> Void
    /// PR を出してから、待つチェックが出るまで待つ長さ
    var checksTimeout: TimeInterval = 30 * 60
    /// 試しの 1 本をマージしてから、develop の Build が終わるまで待つ長さ
    var verifyTimeout: TimeInterval = 90 * 60

    /// 進めた相手の様子。書かなくてよければ nil
    struct Step {
        var target: AppKitFile.Target
        /// 入れた版を書く（`repo.json` の `appKit` か、テンプレートの `appKit`）
        var installed = false
    }

    func advance() async throws(CommanderError) {
        guard let file = try await context.readable(AppKitFile.self, at: StatePath.appKit), let rollout = file.rollout,
              rollout.state == .running else { return }
        let pin = AppKitFile.Pin(version: rollout.version, ref: rollout.ref)
        let release: AppKitRelease
        do throws(AppKitSourceError) {
            release = try await source.release(pin)
        } catch {
            log("app-kit \(pin.version) を読めないので、広げるのを次の生きている印まで待つ（\(error)）")
            return
        }
        if let current = rollout.targets.first(where: { [.open, .verifying].contains($0.state) }) {
            let step = await follow(current, release: release, rollout: rollout)
            if step.target != current || step.installed { try await record(step, in: rollout) }
            return
        }
        for candidate in try await candidates(file: file, rollout: rollout) {
            var step = await start(candidate, release: release, rollout: rollout, file: file)
            // 試しの 1 本に出せなければ、残りにも出さない
            if candidate.repo == rollout.pilot, step.target.state == .skipped {
                step.target.state = .failed
                step.target.problem = "試しの 1 本に出せない（\(step.target.problem ?? "")）。司令塔の設定で試しの 1 本を替えるか、先に入れ替える"
            }
            try await record(step, in: rollout)
            // 出さなかった・もう入っていた相手は、続けて次を確かめる。PR を出したら次の印まで待つ
            if step.target.state == .open || step.target.state == .failed && candidate.repo == rollout.pilot { return }
        }
        try await finish(rollout)
    }

    // MARK: - 相手

    struct Candidate: Equatable {
        var repo: RepositoryFullName
        var kind: AppKitFile.Target.Kind
    }

    /// まだ確かめていない相手（試しの 1 本 → 対象のリポジトリ（名前の順）→ 入れ替え済みのテンプレート）
    func candidates(file: AppKitFile, rollout: AppKitFile.Rollout) async throws(CommanderError) -> [Candidate] {
        let repositories = try await context.repositories().sorted { $0.rawValue.lowercased() < $1.rawValue.lowercased() }
        let templates = file.templates.filter { $0.appKit != nil }.map(\.repo)
        var ordered = [Candidate(repo: rollout.pilot, kind: templates.contains(rollout.pilot) ? .template : .repository)]
        ordered += repositories.filter { $0 != rollout.pilot }.map { Candidate(repo: $0, kind: .repository) }
        ordered += templates.filter { $0 != rollout.pilot }.map { Candidate(repo: $0, kind: .template) }
        return ordered.filter { rollout.target($0.repo) == nil }
    }

    /// 相手を確かめ、要れば写すファイルを置き換える PR を出す
    func start(_ candidate: Candidate, release: AppKitRelease, rollout: AppKitFile.Rollout, file: AppKitFile) async -> Step {
        let now = context.timestamp
        let skip = { (problem: String) in
            Step(target: .init(repo: candidate.repo, kind: candidate.kind, state: .skipped, problem: problem, updatedAt: now))
        }
        let installed: RepositoryFile.AppKit?
        var base: String?
        var checks = ProtectionPolicy.defaultRequiredChecks
        switch candidate.kind {
        case .template:
            installed = file.templates.first { $0.repo == candidate.repo }?.appKit
        case .repository:
            let repository: RepositoryFile?
            do {
                repository = try await context.readable(RepositoryFile.self, at: StatePath.repository(candidate.repo))
            } catch {
                return skip("repo.json を読めない（\(error)）")
            }
            guard let repository, !repository.isRemoved else { return skip("対象から外している") }
            installed = repository.appKit
            base = repository.build?.baseBranch
            checks = Self.requiredChecks(of: repository)
            if installed == nil {
                if let setup = repository.setup?.workflows, setup.state == .open, setup.appKit != nil, let number = setup.pullRequest {
                    return skip("app-kit への入れ替えの準備の PR（#\(number)）が開いている。承認すると入る")
                }
                return skip("まだ app-kit に入れ替えていない（リポジトリの画面の「準備をやり直す」で入れ替える）")
            }
        }
        guard let installed else { return skip("まだ app-kit に入れ替えていない") }
        if let version = installed.version, version.major != rollout.version.major {
            return skip("major が違う（\(version) → \(rollout.version)）ので広げない。major を上げる入れ替えは、まだ人が手で行う")
        }
        if installed.ref == rollout.ref, installed.drift == nil {
            return Step(target: .init(repo: candidate.repo, kind: candidate.kind, state: .done, updatedAt: now))
        }
        return await open(candidate, base: base, checks: checks, release: release, rollout: rollout)
    }

    /// 写すファイルのうち版の中身と違うものを置き換える PR を出す。もう同じなら PR を出さずに入れたことにする
    private func open(
        _ candidate: Candidate,
        base configured: String?,
        checks: [String],
        release: AppKitRelease,
        rollout: AppKitFile.Rollout
    ) async -> Step {
        let now = context.timestamp
        let fail = { (problem: String) in
            Step(target: .init(repo: candidate.repo, kind: candidate.kind, state: .failed, problem: problem, updatedAt: now))
        }
        let github: GitHubPullRequests
        switch await admin.pullRequests(for: candidate.repo, now: context.now()) {
        case let .success(made): github = made
        case let .failure(refusal): return fail(refusal.description)
        }
        do throws(PullRequestError) {
            let base: String
            if let configured { base = configured } else { base = try await github.repositorySettings().defaultBranch }
            guard let head = try await github.branchHead(base) else { throw .notFound }
            let files = try await github.files(at: head)
            let changes = try await Self.changes(release: release, files: files, github: github)
            guard !changes.isEmpty else {
                return Step(target: .init(repo: candidate.repo, kind: candidate.kind, state: .done, updatedAt: now), installed: true)
            }
            let branch = AppKitPolicy.branch(for: rollout.version)
            _ = try await github.commitChanges(changes, onto: head, branch: branch, message: "[ci] app-kit を \(rollout.version) に上げる")
            let pullRequest: PullRequest
            if let existing = try await github.openPullRequest(head: branch, base: base) {
                pullRequest = existing
            } else {
                let body = Self.body(rollout: rollout, paths: changes.keys.sorted(), release: release, checks: checks)
                let draft = PullRequestDraft(base: base, head: branch, title: "【CI】app-kit を \(rollout.version) に上げる", body: body)
                pullRequest = try await github.openPullRequest(draft).pullRequest
            }
            log("\(candidate.repo) に app-kit \(rollout.version) に上げる PR #\(pullRequest.number) を出した")
            return Step(target: .init(
                repo: candidate.repo,
                kind: candidate.kind,
                state: .open,
                pullRequest: pullRequest.number,
                head: pullRequest.headSHA,
                updatedAt: now
            ))
        } catch {
            await admin.note(error, owner: candidate.repo.owner, now: context.now())
            return fail(RepositorySetupRunner.reason("app-kit を \(rollout.version) に上げる PR を出せない", error))
        }
    }

    /// 写すファイルのうち、版の中身と違うもの（`.github/app-kit.json` の `unmanaged` は除く）
    static func changes(
        release: AppKitRelease,
        files: [TreeFile],
        github: GitHubPullRequests
    ) async throws(PullRequestError) -> [String: String?] {
        let shas = Dictionary(files.map { ($0.path, $0.sha) }) { first, _ in first }
        var unmanaged: Set<String> = []
        if let config = shas[AppKitPolicy.configPath], case let .some(.some(text)) = try await github.blobTexts([config])[config] {
            unmanaged = Set(AppKitAdoptionPlanner.existingUnmanaged(text))
        }
        var changes: [String: String?] = [:]
        for path in release.manifest.managed where !unmanaged.contains(path) {
            guard let text = release.managed[path], shas[path] != GitBlob.sha(of: text) else { continue }
            changes[path] = .some(text)
        }
        return changes
    }

    /// 対象のリポジトリの PR で待つチェック（保護を掛けていれば必須のチェック、無ければビルドの設定の子 PR のチェック）
    static func requiredChecks(of repository: RepositoryFile) -> [String] {
        if repository.protection.appliedAt != nil { return repository.protection.requiredChecks ?? ProtectionPolicy.defaultRequiredChecks }
        return repository.build?.childChecks ?? ProtectionPolicy.defaultRequiredChecks
    }

    static func body(rollout: AppKitFile.Rollout, paths: [String], release: AppKitRelease, checks: [String]) -> String {
        let link = "[app-kit](https://github.com/\(AppKitPolicy.repository.rawValue)/tree/\(rollout.ref))"
        return """
            AskHub の司令塔が、人が承認した app-kit の版を広げるために出した PR です（`docs/renewal/app-kit.md` の「版を広げる」）。

            写すファイルを、共通リポジトリ \(link) の \(rollout.version)（`\(rollout.ref)`）の中身に置き換えます。

            \(paths.map { "- `\($0)`" }.joined(separator: "\n"))

            待つチェック（\(checks.joined(separator: "・"))）が通ったら、司令塔がこの PR の head のまま merge commit でマージします。
            写すファイルのほかのファイルが変わったら、マージせずに止めます。直すときは app-kit で直して版を上げます（このリポジトリで直すと、次に版を上げたときに上書きされます）。
            """
    }

    // MARK: - 書く

    /// 相手の様子を `app-kit.json` に書き、入れたなら版を書く。試しの 1 本で止めたら、広げるのを止める。
    /// 読んだ後に人がやめた・広げ直したなら書かない
    func record(_ step: Step, in rollout: AppKitFile.Rollout) async throws(CommanderError) {
        let now = context.timestamp
        let pin = AppKitFile.Pin(version: rollout.version, ref: rollout.ref)
        let installation = RepositoryFile.AppKit(ref: rollout.ref, version: rollout.version, installedAt: now)
        if step.installed, step.target.kind == .repository {
            do {
                let path = StatePath.repository(step.target.repo)
                let message = "\(step.target.repo) に app-kit \(pin.version) を入れた"
                try await context.files.update(RepositoryFile.self, at: path, message: message) {
                    $0.appKit = installation
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
        let message = "app-kit \(pin.version) を広げる: \(step.target.repo) は \(step.target.state.rawValue)"
        try await context.updateAppKit(message: message) { file in
            guard var current = file.rollout, current.version == rollout.version, current.origin == rollout.origin,
                  current.state == .running else { return false }
            if let index = current.targets.firstIndex(where: { $0.repo == step.target.repo }) {
                current.targets[index] = step.target
            } else {
                current.targets.append(step.target)
            }
            if step.target.state == .failed, step.target.repo == current.pilot {
                current.state = .failed
                current.problem = "試しの 1 本 \(current.pilot) で止めた（\(step.target.problem ?? "")）。残りには出していない"
            }
            current.updatedAt = now
            file.rollout = current
            if step.installed, step.target.kind == .template,
               let index = file.templates.firstIndex(where: { $0.repo == step.target.repo }) {
                file.templates[index].appKit = installation
            }
            return true
        }
    }

    /// 出す相手が残っていなければ、広げ終わる（失敗した相手があれば止めたままにする）
    func finish(_ rollout: AppKitFile.Rollout) async throws(CommanderError) {
        let now = context.timestamp
        let wrote = try await context.updateAppKit(message: "app-kit \(rollout.version) を広げ終わった") { file in
            guard var current = file.rollout, current.version == rollout.version, current.origin == rollout.origin,
                  current.state == .running else { return false }
            let failed = current.targets.filter { $0.state == .failed }.map(\.repo.rawValue)
            if failed.isEmpty {
                current.state = .finished
                current.problem = nil
                file.adoption = .init(version: current.version, ref: current.ref)
            } else {
                current.state = .failed
                current.problem = "止めた相手がある（\(failed.joined(separator: "・"))）。もう一度試すか、やめる"
            }
            current.updatedAt = now
            file.rollout = current
            return true
        }
        if wrote { log("app-kit \(rollout.version) を広げ終わった") }
    }
}

extension CommanderContext {
    /// `app-kit.json` を書き直す（無ければ空から作る）。書いたら true
    @discardableResult
    func updateAppKit(message: String, _ change: (inout AppKitFile) -> Bool) async throws(CommanderError) -> Bool {
        var wrote = false
        do {
            try await files.update(AppKitFile.self, at: StatePath.appKit, message: message) { file in
                wrote = change(&file)
                return wrote
            }
        } catch .notFound {
            var file = AppKitFile()
            guard change(&file) else { return false }
            do {
                try await files.create(file, at: StatePath.appKit, message: message)
            } catch .alreadyExists {
                return try await updateAppKit(message: message, change)
            } catch {
                throw .files(error)
            }
            return true
        } catch {
            throw .files(error)
        }
        return wrote
    }
}
