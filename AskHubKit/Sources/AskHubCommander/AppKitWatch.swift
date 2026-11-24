import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// 共通リポジトリ app-kit の見張り（`docs/renewal/app-kit.md` の「版」「版を広げる」「ずれの点検」）。司令塔が生きている印を書くたびに `start()` を呼ぶ。
///
/// - 版: `releaseInterval` ごとに app-kit のタグを `git ls-remote` で読み、新しい版と `CHANGELOG.md` の変更点を `app-kit.json` に書く
/// - 広げる: 人が広げると押した版を、1 歩ずつ進める（`AppKitRolloutDriver`。管理用のトークン）
/// - ずれ: `driftInterval` ごとに、app-kit を入れたリポジトリとテンプレートの写すファイルを毎日のトークンで読み、`appKit.drift` に書く
///   （自動で行うので、管理用のトークンは使わない。直すのは、人が版を広げ直したとき）
public actor AppKitWatch {
    nonisolated let context: CommanderContext
    nonisolated let source: any AppKitSource
    /// リポジトリを受け取り、毎日のトークンで読む部品を返す
    nonisolated let github: @Sendable (RepositoryFullName) -> GitHubPullRequests
    nonisolated let admin: AdminGitHub?
    nonisolated let log: @Sendable (String) -> Void
    nonisolated let releaseInterval: TimeInterval
    nonisolated let driftInterval: TimeInterval
    private var releasesCheckedAt: Date?
    private var driftCheckedAt: [RepositoryFullName: Date] = [:]
    private var running = false

    public init(
        context: CommanderContext,
        source: any AppKitSource,
        github: @escaping @Sendable (RepositoryFullName) -> GitHubPullRequests,
        admin: AdminGitHub?,
        log: @escaping @Sendable (String) -> Void,
        releaseInterval: Duration = .seconds(60 * 60),
        driftInterval: Duration = .seconds(6 * 60 * 60)
    ) {
        self.context = context
        self.source = source
        self.github = github
        self.admin = admin
        self.log = log
        self.releaseInterval = TimeInterval(releaseInterval.components.seconds)
        self.driftInterval = TimeInterval(driftInterval.components.seconds)
    }

    /// 周の外で、時期の来たものを進める。前に始めたものが終わっていなければ、何もしない
    nonisolated public func start() {
        Task { await tick() }
    }

    func tick() async {
        guard !running else { return }
        running = true
        defer { running = false }
        if releasesCheckedAt.map({ context.now().timeIntervalSince($0) >= releaseInterval }) ?? true {
            await refreshReleases()
            releasesCheckedAt = context.now()
        }
        if let admin {
            do {
                try await AppKitRolloutDriver(context: context, admin: admin, source: source, log: log).advance()
            } catch {
                log("app-kit の版を広げる途中で止まった（\(error)）。次の生きている印で続ける")
            }
        }
        await checkDrift()
    }

    // MARK: - 版

    /// app-kit のタグを読み、見つけていない版を変更点と一緒に書く
    func refreshReleases() async {
        let tags: [AppKitFile.Pin]
        do throws(AppKitSourceError) {
            tags = try await source.tags()
        } catch {
            log("app-kit のタグを読めない（\(error)）。次に読むときにやり直す")
            await write(problem: error.description)
            return
        }
        let known = (try? await context.readable(AppKitFile.self, at: StatePath.appKit))??.releases ?? []
        var found: [AppKitFile.Release] = []
        for tag in tags.prefix(AppKitFile.maximumReleases) {
            if let release = known.first(where: { $0.version == tag.version }), release.ref == tag.ref {
                found.append(release)
                continue
            }
            var changes: String?
            if case let .some(.some(text)) = try? await source.changes(of: tag) { changes = text }
            found.append(.init(version: tag.version, ref: tag.ref, changes: changes, foundAt: context.timestamp))
            log("app-kit \(tag.version)（\(tag.ref.prefix(7))）を見つけた")
        }
        let now = context.timestamp
        do {
            try await context.updateAppKit(message: "app-kit の版を書く") { file in
                let templates = Self.templates(file.templates)
                let adoption = file.adoption ?? found.first.map { .init(version: $0.version, ref: $0.ref) }
                let changed = found != file.releases || file.problem != nil || templates != file.templates || adoption != file.adoption
                guard changed else { return false }
                file.releases = found
                file.problem = nil
                file.adoption = adoption
                file.templates = templates
                file.checkedAt = now
                return true
            }
        } catch {
            log("app-kit の版を書けない（\(error)）。次に読むときにやり直す")
        }
    }

    /// テンプレートの一覧（`AppKitPolicy.templates` の順。前に書いた版は残す）
    static func templates(_ current: [AppKitFile.Template]) -> [AppKitFile.Template] {
        AppKitPolicy.templates.map { repo in current.first { $0.repo == repo } ?? .init(repo: repo) }
    }

    private func write(problem: String) async {
        let now = context.timestamp
        _ = try? await context.updateAppKit(message: "app-kit のタグを読めなかった") { file in
            guard file.problem != problem else { return false }
            file.problem = String(String.UnicodeScalarView(problem.unicodeScalars.prefix(1_000)))
            file.checkedAt = file.checkedAt ?? now
            return true
        }
    }

    // MARK: - ずれ

    /// app-kit を入れたリポジトリとテンプレートのうち、時期の来たものを確かめる
    func checkDrift() async {
        guard let file = try? await context.readable(AppKitFile.self, at: StatePath.appKit) else { return }
        let repositories: [RepositoryFullName]
        do {
            repositories = try await context.repositories()
        } catch {
            log("app-kit のずれを確かめるリポジトリの一覧を読めない（\(error)）")
            return
        }
        for repo in repositories + file.templates.map(\.repo) where isDue(repo) {
            do {
                try await check(repo, releases: file.releases)
            } catch PullRequestError.rateLimited(let wait) {
                log("app-kit のずれを確かめる途中で GitHub の上限に当たった（\(wait.components.seconds) 秒）。残りは次の生きている印で確かめる")
                return
            } catch {
                log("\(repo) の app-kit のずれを確かめられない（\(error)）。次に確かめるときにやり直す")
            }
            driftCheckedAt[repo] = context.now()
        }
    }

    private func isDue(_ repo: RepositoryFullName) -> Bool {
        guard let checked = driftCheckedAt[repo] else { return true }
        return context.now().timeIntervalSince(checked) >= driftInterval
    }

    /// 1 つのリポジトリ（かテンプレート）のずれを確かめ、変わっていれば書く
    func check(_ repo: RepositoryFullName, releases: [AppKitFile.Release]) async throws {
        let isTemplate = AppKitPolicy.templates.contains(repo)
        var installed: RepositoryFile.AppKit?
        var build: RepositoryFile.Build?
        if isTemplate {
            installed = try await context.readable(AppKitFile.self, at: StatePath.appKit)?.templates.first { $0.repo == repo }?.appKit
        } else {
            let path = StatePath.repository(repo)
            guard let file = try await context.readable(RepositoryFile.self, at: path), !file.isRemoved else { return }
            // まだ記録の無いリポジトリも読む（手で入れ替えた・テンプレートから作ったリポジトリは、呼んでいる版を書く）
            installed = file.appKit
            build = file.build
        }
        let observed = try await AppKitObserved.read(github(repo), base: build?.baseBranch)
        let catalog = AppKitCatalog(releases: releases, source: source)
        let now = context.timestamp
        let next = try await Self.installation(installed: installed, observed: observed, build: build, catalog: catalog, now: now)
        guard next != installed else { return }
        try await record(next, for: repo, isTemplate: isTemplate, previous: installed)
    }

    /// 読んだ様子から、入っている版とずれを決める。呼んでいるコミットが見つけた別の版で、写すファイルがその版と同じなら、
    /// その版が入ったとみなす（人が GitHub で版の上げの PR をマージした・手で入れ替えたテンプレート）。
    /// まだ記録の無いリポジトリ（手で入れ替えた）は、ずれがあっても呼んでいる版を書き、ずれも書く（入れた時刻は分からないので書かない）
    static func installation(
        installed: RepositoryFile.AppKit?,
        observed: AppKitObserved,
        build: RepositoryFile.Build?,
        catalog: AppKitCatalog,
        now: Timestamp
    ) async throws -> RepositoryFile.AppKit? {
        if let caller = observed.callerRef, caller != installed?.ref, let candidate = try await catalog.release(ref: caller) {
            let problems = AppKitDrift.problems(release: candidate, observed: observed, build: build)
            let pin = candidate.pin
            if problems.isEmpty {
                return RepositoryFile.AppKit(ref: pin.ref, version: pin.version, installedAt: installed == nil ? nil : now)
            }
            if installed == nil {
                return RepositoryFile.AppKit(ref: pin.ref, version: pin.version, drift: AppKitDrift.drift(problems, at: now))
            }
        }
        if installed == nil, let caller = observed.callerRef {
            return RepositoryFile.AppKit(ref: caller, drift: AppKitDrift.drift([AppKitDrift.unknownRef(caller)], at: now))
        }
        guard var installed else { return nil }
        let problems: [String]
        if let release = try await catalog.release(ref: installed.ref) {
            problems = AppKitDrift.problems(release: release, observed: observed, build: build)
        } else {
            problems = [AppKitDrift.unknownRef(installed.ref)]
        }
        let limited = Array(problems.prefix(AppKitDrift.maximumProblems))
        if limited != installed.drift?.problems ?? [] {
            installed.drift = limited.isEmpty ? nil : ProtectionDrift(foundAt: now, problems: limited)
        }
        return installed
    }

    /// 読み始めた後に、入れた版が変わっていたら（広げた・準備の PR をマージした）書かない
    private func record(
        _ next: RepositoryFile.AppKit?,
        for repo: RepositoryFullName,
        isTemplate: Bool,
        previous: RepositoryFile.AppKit?
    ) async throws {
        let message = "\(repo) の app-kit のずれを書く"
        if isTemplate {
            try await context.updateAppKit(message: message) { file in
                guard let index = file.templates.firstIndex(where: { $0.repo == repo }),
                      file.templates[index].appKit == previous else { return false }
                file.templates[index].appKit = next
                return true
            }
        } else {
            do {
                try await context.files.update(RepositoryFile.self, at: StatePath.repository(repo), message: message) {
                    guard !$0.isRemoved, $0.appKit == previous else { return false }
                    $0.appKit = next
                    return true
                }
            } catch {
                throw CommanderError.files(error)
            }
        }
        if next?.ref != previous?.ref {
            log("\(repo) は app-kit \(next?.version?.rawValue ?? next?.ref ?? "") を呼んでいる")
        } else {
            log(next?.drift.map { "\(repo) の app-kit がずれている: \($0.problems.joined(separator: "・"))" } ?? "\(repo) の app-kit のずれが無くなった")
        }
    }
}

/// 見つけた版と、その中身を読む部品
struct AppKitCatalog {
    var releases: [AppKitFile.Release]
    var source: any AppKitSource

    /// コミットが見つけた版なら、その中身。見つけた版でなければ nil
    func release(ref: String) async throws -> AppKitRelease? {
        guard let found = releases.first(where: { $0.ref == ref }) else { return nil }
        return try await source.release(.init(version: found.version, ref: found.ref))
    }
}

/// 対象のリポジトリの base の先頭のコミットの、app-kit に関わる様子（毎日のトークンで読む）
struct AppKitObserved: Equatable {
    /// ファイルのパス → git の blob の sha
    var files: [String: String]
    /// `.github/app-kit.json` の中身。無ければ nil
    var config: String?
    /// `build.yml` が呼んでいる app-kit のコミット。呼んでいなければ nil
    var callerRef: String?

    static func read(_ github: GitHubPullRequests, base configured: String?) async throws -> Self {
        let base: String
        if let configured { base = configured } else { base = try await github.repositorySettings().defaultBranch }
        guard let head = try await github.branchHead(base) else { throw PullRequestError.notFound }
        let tree = try await github.files(at: head)
        let files = Dictionary(tree.map { ($0.path, $0.sha) }) { first, _ in first }
        let wanted = [AppKitPolicy.configPath, ".github/workflows/build.yml"].compactMap { files[$0] }
        let texts = wanted.isEmpty ? [:] : try await github.blobTexts(wanted)
        let text = { (path: String) -> String? in
            guard let sha = files[path], case let .some(.some(text)) = texts[sha] else { return nil }
            return text
        }
        let build = ".github/workflows/build.yml"
        let caller = text(build).flatMap { AppKitCaller.ref(in: [WorkflowFile(path: build, text: $0)]) }
        return Self(files: files, config: text(AppKitPolicy.configPath), callerRef: caller)
    }
}

/// 入っている版の写すファイルのずれ（人が読む文）
enum AppKitDrift {
    /// 書くずれの数の上限
    static let maximumProblems = 20

    static func problems(release: AppKitRelease, observed: AppKitObserved, build: RepositoryFile.Build?) -> [String] {
        var problems: [String] = []
        guard let config = observed.config else { return ["\(AppKitPolicy.configPath) が無い"] }
        let unmanaged = Set(AppKitAdoptionPlanner.existingUnmanaged(config))
        let version = release.pin.version
        for path in release.manifest.managed where !unmanaged.contains(path) {
            guard let text = release.managed[path] else { continue }
            switch observed.files[path] {
            case nil: problems.append("\(path) が無い（app-kit \(version) の写すファイル）")
            case let sha? where sha != GitBlob.sha(of: text): problems.append("\(path) が app-kit \(version) の中身と違う")
            default: break
            }
        }
        if let xcode = build?.xcode, let data = config.data(using: .utf8),
           let values = try? JSONDecoder().decode(ConfigNames.self, from: data) {
            if let project = values.project, project != xcode.project {
                problems.append("\(AppKitPolicy.configPath) の project（\(project)）が、ビルドの設定（\(xcode.project)）と違う")
            }
            if let scheme = values.scheme, scheme != xcode.scheme {
                problems.append("\(AppKitPolicy.configPath) の scheme（\(scheme)）が、ビルドの設定（\(xcode.scheme)）と違う")
            }
        }
        return problems.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(500))) }
    }

    /// 書くずれ（上限まで）。無ければ nil
    static func drift(_ problems: [String], at now: Timestamp) -> ProtectionDrift? {
        let limited = Array(problems.prefix(maximumProblems))
        return limited.isEmpty ? nil : ProtectionDrift(foundAt: now, problems: limited)
    }

    static func unknownRef(_ ref: String) -> String {
        "呼んでいる app-kit のコミット \(ref.prefix(7)) が、見つけた版に無い"
    }

    private struct ConfigNames: Decodable {
        let project: String?
        let scheme: String?
    }
}
