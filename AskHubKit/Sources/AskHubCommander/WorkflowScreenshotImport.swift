import AskHubBuild
import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 撮影のワークフローの実行の artifact を取り込み、配信中の版のスクショと比べる（`capture: actions`。
/// `docs/renewal/store-screenshots.md` の「取り込みと比べ方」）。
///
/// artifact（`screenshots-<名前>`）を `artifacts` の配置グループごとに落として取り出し、`languages` の言語のフォルダの PNG を名前の順に、
/// App Store の 1 枚目・2 枚目… とする。Actions は 1 回ですべての言語を撮るので、すべての言語を比べる。配信中の版が無い（初めての版）・
/// 配信中の版にその組が無いときは、すべて新しい画面にする。見本は最後に 1 回のコミットでまとめて書く
struct WorkflowScreenshotImport: Sendable {
    var context: CommanderContext
    var store: any AppStoreConnectSubmitting
    var hosting: any ReleaseHosting
    var extractor: any StoreScreenshotArtifactExtracting
    /// 撮った元の画像のフォルダ（常時オンの Mac）
    var originals: URL
    var log: @Sendable (String) -> Void

    /// 取り込んで比べる。撮れなかったときも結果（`failed`）を返し、投げるのは待てば直るとき（GitHub・App Store Connect の上限など）だけ
    func execute(
        _ file: SubmissionFile,
        runID: Int,
        commit: String,
        app: AppStoreApp,
        workflow: StoreScreenshotWorkflow
    ) async throws -> SubmissionFile.StoreScreenshots {
        let started = file.screenshots?.startedAt ?? context.timestamp
        let run = file.screenshots?.run
        func failed(_ message: String) -> SubmissionFile.StoreScreenshots {
            .init(state: .failed, commit: commit, startedAt: started, finishedAt: context.timestamp, failure: message, run: run)
        }
        let live: Live
        do {
            live = try await self.live(app: app, workflow: workflow)
        } catch let unavailable as StoreScreenshotRun.Unavailable {
            return failed(unavailable.message)
        }
        let liveTypes = Set(live.sets.keys.map(\.displayType))
        var skipped = liveTypes.subtracting(workflow.artifacts.keys).sorted().map { type in
            SubmissionFile.SkippedDisplayType(displayType: type, reason: Self.unconfiguredReason)
        }
        let artifacts = try await github { () throws(PullRequestError) in try await hosting.runArtifacts(file.repo, runID: runID) }
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("askhub-artifacts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workspace) }
        // 一部だけを撮り直すときは、撮り直す組だけを取り込み、ほかの組は引き継ぐ（`ReleaseWatch+ScreenshotRetake`）
        let retake = file.screenshots?.retake.flatMap { $0.isPartial ? $0 : nil }
        var imported = Imported(
            comparer: .init(store: store, repo: file.repo, version: file.version, commit: commit, originals: originals),
            skipped: skipped,
            retake: retake
        )
        for (type, name) in try await importable(workflow, retake: retake, skipped: &imported.skipped) {
            switch try await download(name, from: artifacts, repo: file.repo, into: workspace) {
            case let .success(folders):
                try await imported.compare(type, artifact: name, folders: folders, live: live, workflow: workflow)
            case let .failure(problem):
                imported.skipped.append(.init(displayType: type, reason: problem.message))
            }
        }
        // クライアントは最初の組の言語を基準の言語とみなすので、基準の言語の組を先に並べる
        let carried = retake == nil ? [] : (file.screenshots?.sets ?? [])
        let base = workflow.baseLocale
        let sets = (carried + imported.sets).sorted { Self.order($0, base: base) < Self.order($1, base: base) }
        skipped = imported.skipped
        let previews = imported.previews
        guard sets.contains(where: { $0.locale == workflow.baseLocale }) else {
            return failed(skipped.first?.reason ?? "基準の言語（\(workflow.baseLocale)）のスクショを取り込めなかった")
        }
        try await StoreScreenshotComparer.writePreviews(previews, of: file, to: context.store)
        let first = live.isFirstVersion ? "。初めての版なので、すべて新しい画面" : ""
        log("\(file.repo) の \(file.version) のスクショを取り込んだ（実行 \(runID)。差のある組 \(sets.filter(\.isChanged).count) / \(sets.count)\(first)）")
        let finished = context.timestamp
        return .init(state: .captured, commit: commit, startedAt: started, finishedAt: finished, sets: sets, skipped: skipped, run: run)
    }

    /// 取り込む組（配置グループ → artifact の表示サイズの名前。配置グループの順）。一部だけ撮り直すときは撮り直す組だけ。
    /// リファレンスデータに無い配置グループ（撮り方の書き間違い）は、審査に出すときに黙って落ちるので、取り込まずに `skipped` にわけを足す
    private func importable(
        _ workflow: StoreScreenshotWorkflow,
        retake: SubmissionFile.Retake?,
        skipped: inout [SubmissionFile.SkippedDisplayType]
    ) async throws -> [(type: String, name: String)] {
        let known = try await call { () throws(AppStoreConnectError) in try await store.displayTypePlatforms() }
        var importable: [(type: String, name: String)] = []
        for (type, name) in workflow.artifacts.sorted(by: { $0.key < $1.key })
            where retake.map({ $0.displayTypes.isEmpty || $0.displayTypes.contains(type) }) ?? true {
            guard known[type] != nil else {
                skipped.append(.init(displayType: type, reason: Self.unknownPlacementReason(type)))
                continue
            }
            importable.append((type, name))
        }
        return importable
    }

    /// 取り込んだ組と見本（状態リポジトリのパス → base64 の文字）と、取り込めなかった組のわけ
    struct Imported {
        var comparer: StoreScreenshotComparer
        var sets: [SubmissionFile.ScreenshotSet] = []
        var previews: [String: String] = [:]
        var skipped: [SubmissionFile.SkippedDisplayType]
        /// 一部だけを撮り直す頼み（撮り直す言語だけを取り込む）
        var retake: SubmissionFile.Retake?

        /// 1 つの artifact（表示サイズ）の、言語ごとのフォルダの PNG を名前の順に並べ、配信中の版の組と比べる
        mutating func compare(
            _ type: String,
            artifact name: String,
            folders: [String: [URL]],
            live: Live,
            workflow: StoreScreenshotWorkflow
        ) async throws {
            for locale in live.locales where retake?.covers(displayType: type, locale: locale) ?? true {
                let folder = workflow.languages[locale]?.language ?? locale
                guard let files = folders[folder], !files.isEmpty else {
                    skipped.append(.init(displayType: type, reason: "\(locale): artifact の screenshots-\(name) に \(folder) のフォルダが無い"))
                    continue
                }
                guard files.count <= StoreScreenshotSettings.maximumShots else {
                    skipped.append(.init(displayType: type, reason: "\(locale): 画像が \(StoreScreenshotSettings.maximumShots) 枚を超える"))
                    continue
                }
                let target = StoreScreenshotTarget(displayType: type, locale: locale)
                let shots = files.map { CapturedShot(name: $0.deletingPathExtension().lastPathComponent, file: $0) }
                let compared = try await comparer.compare(target, shots: shots, current: live.sets[target]?.screenshots ?? [])
                sets.append(compared.set)
                previews.merge(compared.previews) { $1 }
            }
        }
    }

    /// 組の並び（基準の言語が先、ほかは言語・表示サイズの名前の順）
    static func order(_ set: SubmissionFile.ScreenshotSet, base: String) -> String {
        "\(set.locale == base ? 0 : 1)/\(set.locale)/\(set.displayType)"
    }

    /// 配信中の版の組と、比べる言語（基準の言語が先）
    struct Live {
        var sets: [StoreScreenshotTarget: AppStoreScreenshotSet]
        var locales: [String]
        var isFirstVersion: Bool
    }

    /// 配信中の版の組を読む。配信中の版が無ければ（初めての版）、組は無く、比べる言語は設定のすべて
    private func live(app: AppStoreApp, workflow: StoreScreenshotWorkflow) async throws -> Live {
        let configured = Self.ordered(Array(workflow.languages.keys), base: workflow.baseLocale)
        let versions = try await call { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        guard let live = ReleaseWatch.liveVersion(versions) else {
            return Live(sets: [:], locales: configured, isFirstVersion: true)
        }
        let localizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: live.id) }
        var sets: [StoreScreenshotTarget: AppStoreScreenshotSet] = [:]
        for localization in localizations where workflow.languages[localization.locale] != nil {
            let found = try await call { () throws(AppStoreConnectError) in try await store.screenshotSets(of: localization.id) }
            for set in found { sets[StoreScreenshotTarget(displayType: set.displayType, locale: localization.locale)] = set }
        }
        let liveLocales = localizations.map(\.locale).filter { workflow.languages[$0] != nil }
        guard liveLocales.contains(workflow.baseLocale) else {
            throw StoreScreenshotRun.Unavailable(message: "配信中の版に基準の言語（\(workflow.baseLocale)）の掲載文が無い")
        }
        // 配信中の版には必ずスクショがある。配置として読めないなら、比べられないので取り込まない（古い API で上げたスクショは読まない。#1185）
        guard sets.contains(where: { $0.key.locale == workflow.baseLocale && !$0.value.screenshots.isEmpty }) else {
            throw StoreScreenshotRun.Unavailable(
                message: "配信中の版の基準の言語（\(workflow.baseLocale)）のスクショを、App Asset Library の配置として読めない（App Store Connect で確かめる）"
            )
        }
        // 設定にあって配信中の版に無い言語（はじめて足した言語）も、組の無い言語として比べる（すべて新しい画面）
        return Live(sets: sets, locales: configured, isFirstVersion: false)
    }

    /// 基準の言語を先に、ほかは名前の順
    static func ordered(_ locales: [String], base: String) -> [String] {
        Set(locales).sorted { ($0 == base ? 0 : 1, $0) < ($1 == base ? 0 : 1, $1) }
    }

    /// artifact を落として取り出す。無い・期限切れ・大きすぎる・形が違うときは、その表示サイズを撮らなかったわけ
    private func download(
        _ name: String,
        from artifacts: [RunArtifact],
        repo: RepositoryFullName,
        into workspace: URL
    ) async throws -> Result<[String: [URL]], ArtifactProblem> {
        let full = "screenshots-\(name)"
        guard let artifact = artifacts.first(where: { $0.name == full }) else {
            return .failure(ArtifactProblem("撮影の実行に artifact \(full) が無い（その表示サイズの撮影のジョブが失敗した・名前が違う）"))
        }
        guard !artifact.expired else { return .failure(ArtifactProblem("artifact \(full) の期限が切れた。撮り直す")) }
        guard artifact.size <= UnzipArtifactExtractor.maximumZipBytes else {
            return .failure(ArtifactProblem("artifact \(full) が大きすぎる（\(artifact.size / 1_048_576) MB）"))
        }
        let zip: Data
        do throws(PullRequestError) {
            zip = try await hosting.downloadArtifact(repo, id: artifact.id)
        } catch .notFound {
            // 一覧を読んだ後に消えた・期限が切れた。その表示サイズだけ飛ばし、ほかの artifact は取り込む
            return .failure(ArtifactProblem("artifact \(full) を落とせない（消えた・期限が切れた）。撮り直す"))
        } catch {
            return try await github { () throws(PullRequestError) in throw error }
        }
        do {
            return .success(try await extractor.extract(zip, into: workspace.appendingPathComponent(name, isDirectory: true)))
        } catch let problem as ArtifactProblem {
            return .failure(ArtifactProblem("artifact \(full) を取り込めない（\(problem.message)）"))
        } catch {
            throw ReleaseStepProblem("artifact \(full) を取り出せない（\(error)）", needsHuman: false)
        }
    }

    /// 撮り方に無い表示サイズのわけ
    static let unconfiguredReason = "撮り方の設定（build.storeScreenshots.artifacts）にこの表示サイズが無い"

    static func unknownPlacementReason(_ type: String) -> String {
        "配置グループ \(type) が App Store Connect のリファレンスデータに無い。build.storeScreenshots.artifacts を直す"
    }

    private func call<Value>(_ body: () async throws(AppStoreConnectError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw ReleaseWatch.problem(error)
        }
    }

    private func github<Value>(_ body: () async throws(PullRequestError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            switch error {
            case .rateLimited, .serverError, .transport, .cancelled, .malformed, .headChanged:
                throw ReleaseStepProblem("GitHub に届かない（\(error)）", needsHuman: false)
            case .notFound:
                throw ReleaseStepProblem("撮影の実行の artifact が無い（消された・期限が切れた）。撮り直す", needsHuman: true)
            default:
                throw ReleaseStepProblem("GitHub に断られた（\(error)）", needsHuman: true)
            }
        }
    }
}
