import AskHubProtocol
import AskHubPullRequests
import AskHubStateStore
import Foundation

/// App Store での配信を見つけ、リリースの後作業を進める（`docs/renewal/release.md` の「配信の検知と後作業」）。
///
/// 司令塔が生きている印を書くとき（10 分ごと）に `start()` を呼ぶ。前に読んでから `detectInterval` たったリポジトリを、周の外で 1 つずつ
/// App Store Connect で読み、配信中の版の記録（`releases/<版>.json`）を作る。続けて、終わっていない記録の後作業（コミット → タグ →
/// リリース文 → GitHub Release と、次の版の PR）を進める。どの段取りも、作る前にあるかを確かめ、途中で止まってもやり直せば同じになる
public actor ReleaseWatch {
    nonisolated let context: CommanderContext
    /// App Store Connect の読み取り（Apple のチームごとの API キー）。空なら配信を見つけない（後作業だけ進める）
    nonisolated let stores: [any AppStoreConnectReading]
    nonisolated let sources: any ReleaseSourceReading
    nonisolated let hosting: any ReleaseHosting
    nonisolated let drafter: any ReleaseNotesDrafting
    nonisolated let authors: any CommitAuthors
    nonisolated let log: @Sendable (String) -> Void
    /// 1 つのリポジトリの App Store Connect を読む間隔
    nonisolated let detectInterval: TimeInterval

    private var detectedAt: [RepositoryFullName: Date] = [:]
    /// 見つけたアプリと、それを読める鍵（`stores` の番号）。起動し直したら探し直す
    var apps: [RepositoryFullName: (store: Int, app: AppStoreApp)] = [:]
    /// ログに出した知らせ（同じものを見回りのたびに出さない）
    private var reported: Set<String> = []
    private var running = false
    /// 人を待っているもの（リリース文の確認・人が直す後作業）。見回りのたびに作り直し、司令塔の通知（`Notifier`）が読む
    private(set) var blockers: [Blocker] = []

    public init(
        context: CommanderContext,
        stores: [any AppStoreConnectReading],
        sources: any ReleaseSourceReading,
        hosting: any ReleaseHosting,
        drafter: any ReleaseNotesDrafting,
        authors: any CommitAuthors,
        log: @escaping @Sendable (String) -> Void,
        detectInterval: Duration = .seconds(30 * 60)
    ) {
        self.context = context
        self.stores = stores
        self.sources = sources
        self.hosting = hosting
        self.drafter = drafter
        self.authors = authors
        self.log = log
        self.detectInterval = TimeInterval(detectInterval.components.seconds)
    }

    /// 見回りを周の外で始める。前に始めたものが終わっていなければ、何もしない
    nonisolated public func start() {
        Task { await refresh() }
    }

    /// 対象のリポジトリを 1 つずつ見回る。見回っているときに呼ばれたら、何もしない
    func refresh() async {
        guard !running else { return }
        running = true
        defer { running = false }
        let repositories: [RepositoryFullName]
        do {
            repositories = try await context.repositories()
        } catch {
            report("配信を見回るリポジトリの一覧を読めない（\(error)）。次の生きている印のときにやり直す")
            return
        }
        var waiting: [Blocker] = []
        for repo in repositories {
            guard let file = try? await context.readable(RepositoryFile.self, at: StatePath.repository(repo)),
                  file.platform == .apple else {
                continue
            }
            if isDetectDue(repo) {
                await detect(repo, settings: file)
                detectedAt[repo] = context.now()
            }
            waiting += await advanceAll(repo, settings: file).flatMap(Blocker.waiting(on:))
        }
        blockers = waiting
    }

    private func isDetectDue(_ repo: RepositoryFullName) -> Bool {
        guard !stores.isEmpty else { return false }
        guard let detected = detectedAt[repo] else { return true }
        return context.now().timeIntervalSince(detected) >= detectInterval
    }

    // MARK: - 配信を見つける

    /// App Store Connect で配信中の版を読み、記録を作る（あれば、見つけたプラットフォームを足す）
    func detect(_ repo: RepositoryFullName, settings: RepositoryFile) async {
        do {
            guard let found = try await app(of: repo, base: settings.build?.baseBranch) else { return }
            for live in try await stores[found.store].liveVersions(of: found.app.id) {
                guard let build = live.build else {
                    report("\(repo) の \(live.platform.rawValue) \(live.version) は配信中だが、ビルドを読めない。次に読むときにやり直す")
                    continue
                }
                let platform = ReleaseFile.Platform(
                    platform: live.platform, build: build, uploadedAt: live.uploadedAt.map(Timestamp.init), detectedAt: context.timestamp
                )
                try await record(platform, version: live.version, of: repo)
            }
        } catch let error as AppStoreConnectError {
            report("\(repo) の配信を読めない（\(error)）。次に読むときにやり直す")
        } catch {
            report("\(repo) の配信を読めない（\(error)）。次に読むときにやり直す")
        }
    }

    /// リポジトリのアプリ。base の Bundle ID の候補を、鍵ごとに App Store Connect で探す。見つからなければ nil
    private func app(of repo: RepositoryFullName, base: String?) async throws -> (store: Int, app: AppStoreApp)? {
        if let found = apps[repo] { return found }
        let bundleIDs = try await sources.bundleIdentifiers(repo, base: base)
        guard !bundleIDs.isEmpty else {
            report("\(repo) のビルドの設定に Bundle ID が見つからない。配信を見つけられない")
            return nil
        }
        for (index, store) in stores.enumerated() {
            if let app = try await store.apps(bundleIDs: bundleIDs).first {
                apps[repo] = (index, app)
                return (index, app)
            }
        }
        report("\(repo) のアプリ（\(bundleIDs.joined(separator: "・"))）が、どの鍵の App Store Connect にも無い")
        return nil
    }

    nonisolated private func record(
        _ platform: ReleaseFile.Platform,
        version: MarketingVersion,
        of repo: RepositoryFullName
    ) async throws(CommanderError) {
        let path = StatePath.release(repo, version)
        try await context.writingResult { () throws(CommanderError) in
            do throws(StateFileStore.Failure) {
                if try await context.files.read(ReleaseFile.self, at: path) == nil {
                    let file = ReleaseFile(
                        repo: repo, version: version, platforms: [platform], detectedAt: context.timestamp, updatedAt: context.timestamp
                    )
                    do throws(StateFileStore.Failure) {
                        try await context.files.create(file, at: path, message: "\(repo) の \(version) の配信を見つけた")
                        log("\(repo) の \(version)（\(platform.platform.rawValue) のビルド \(platform.build)）の配信を見つけた")
                        return
                    } catch .alreadyExists {
                        // 読んだ後に作られた。下でプラットフォームを足す
                    }
                }
                try await context.files.update(ReleaseFile.self, at: path, message: "\(repo) の \(version) の配信を足す") { file in
                    guard !file.platforms.contains(where: { $0.platform == platform.platform }) else { return false }
                    file.platforms.append(platform)
                    file.updatedAt = context.timestamp
                    return true
                }
            } catch {
                throw .files(error)
            }
        }
    }

    // MARK: - 後作業

    /// 終わっていない記録の後作業を進め、進めた後の記録を返す
    @discardableResult
    func advanceAll(_ repo: RepositoryFullName, settings: RepositoryFile) async -> [ReleaseFile] {
        let entries: [DirectoryEntry]
        do {
            entries = try await context.store.list(StatePath.releases(repo)) ?? []
        } catch {
            report("\(repo) の配信の記録を並べられない（\(error)）。次の見回りでやり直す")
            return []
        }
        let versions = entries.filter { $0.kind == .file && $0.name.hasSuffix(".json") }
            .compactMap { MarketingVersion(rawValue: String($0.name.dropLast(".json".count))) }
            .sorted()
        var advanced: [ReleaseFile] = []
        for version in versions {
            let path = StatePath.release(repo, version)
            guard let file = try? await context.readable(ReleaseFile.self, at: path), !file.isFinished else { continue }
            advanced.append(await advance(file, settings: settings))
        }
        return advanced
    }

    /// 1 つの記録の後作業を、進められるところまで進め、進めた後の記録を返す
    @discardableResult
    func advance(_ release: ReleaseFile, settings: RepositoryFile) async -> ReleaseFile {
        var file = release
        // 次の版の PR は、コミットやタグを待たずに進める（develop の Upload が配信済みの版で断られないように）
        file = await step(.nextVersion, file) { try await self.advanceNextVersion($0, settings: settings) }
        if file.commit == nil { file = await step(.commit, file) { try await self.findCommit($0) } }
        if file.commit != nil, file.tag == nil { file = await step(.tag, file) { try await self.tag($0) } }
        if file.tag != nil, file.githubRelease == nil { file = await step(.githubRelease, file) { try await self.advanceRelease($0) } }
        return file
    }

    /// 1 つの段取り。進めたら記録を書き直したものを返す。進められなければ `problem` に書く（同じ理由なら書き直さない）
    private func step(
        _ step: ReleaseFile.Step,
        _ file: ReleaseFile,
        _ body: (ReleaseFile) async throws -> ReleaseFile?
    ) async -> ReleaseFile {
        do {
            guard let changed = try await body(file) else { return file }
            return try await save(changed, clearing: step)
        } catch let problem as ReleaseStepProblem {
            report("\(file.repo) の \(file.version) の後作業（\(step.rawValue)）を進められない: \(problem.message)")
            let failure = ReleaseFile.Problem(step: step, message: problem.message, needsHuman: problem.needsHuman, at: context.timestamp)
            return (try? await saveProblem(failure, on: file)) ?? file
        } catch {
            report("\(file.repo) の \(file.version) の後作業（\(step.rawValue)）を進められない: \(error)。次の見回りでやり直す")
            return file
        }
    }

    /// 段取りが進めた欄を、今の記録に足して書く（人の意図が同じ記録に書いたものを消さない）
    nonisolated private func save(
        _ changed: ReleaseFile,
        clearing step: ReleaseFile.Step
    ) async throws(CommanderError) -> ReleaseFile {
        let path = StatePath.release(changed.repo, changed.version)
        let message = "\(changed.repo) の \(changed.version) の後作業（\(step.rawValue)）"
        return try await context.writingResult { () throws(CommanderError) -> ReleaseFile in
            do throws(StateFileStore.Failure) {
                return try await context.files.update(ReleaseFile.self, at: path, message: message) { file in
                    let before = file
                    if file.commit == nil { file.commit = changed.commit }
                    if file.tag == nil { file.tag = changed.tag }
                    if file.notes == nil { file.notes = changed.notes }
                    if file.githubRelease == nil { file.githubRelease = changed.githubRelease }
                    if changed.nextVersion != nil, file.nextVersion?.state != .merged { file.nextVersion = changed.nextVersion }
                    if file.problem?.step == step { file.problem = nil }
                    guard file != before else { return false }
                    file.updatedAt = context.timestamp
                    return true
                }.file
            } catch {
                throw .files(error)
            }
        }
    }

    nonisolated private func saveProblem(
        _ problem: ReleaseFile.Problem,
        on file: ReleaseFile
    ) async throws(CommanderError) -> ReleaseFile {
        let path = StatePath.release(file.repo, file.version)
        let message = "\(file.repo) の \(file.version) の後作業を進められない"
        return try await context.writingResult { () throws(CommanderError) -> ReleaseFile in
            do throws(StateFileStore.Failure) {
                return try await context.files.update(ReleaseFile.self, at: path, message: message) { file in
                    // 同じ理由なら書き直さない。待てば直る理由は、文が変わっても（上限の待ち時間など）同じ段取りなら書き直さない
                    if let current = file.problem, current.step == problem.step, current.needsHuman == problem.needsHuman,
                       !problem.needsHuman || current.message == problem.message {
                        return false
                    }
                    file.problem = problem
                    file.updatedAt = context.timestamp
                    return true
                }.file
            } catch {
                throw .files(error)
            }
        }
    }

    func report(_ note: String) {
        if reported.insert(note).inserted { log(note) }
    }
}
