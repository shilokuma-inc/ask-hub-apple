import AskHubBuild
import AskHubProtocol
import AskHubStateStore
import Foundation

/// 撮る組（表示サイズ・言語）
public struct StoreScreenshotTarget: Hashable, Sendable {
    public var displayType: String
    public var locale: String

    public init(displayType: String, locale: String) {
        self.displayType = displayType
        self.locale = locale
    }

    var key: String { "\(displayType)/\(locale)" }
}

/// 撮る頼み（release ブランチの写しで、組ごとに UI テストを流す）
public struct StoreScreenshotCaptureRequest: Sendable {
    public var repo: RepositoryFullName
    public var version: MarketingVersion
    public var commit: String
    /// release ブランチの写し
    public var directory: URL
    public var build: BuildSettings
    public var settings: StoreScreenshotSettings
    public var targets: [StoreScreenshotTarget] = []
}

/// 組ごとの、撮れた画像（添付の順）か撮れなかったわけ
public typealias StoreScreenshotResults = [StoreScreenshotTarget: Result<[CapturedShot], CaptureFailure>]

/// App Store のスクショを撮る道具（本物は `MachineStoreScreenshots`。テストでは差し替える）
public protocol StoreScreenshotCapturing: Sendable {
    /// 組ごとに撮る（`targets` の順）。組ごとに、撮れた画像（添付の順）か撮れなかったわけを返す。投げるのは取り消されたときだけ
    func capture(_ request: StoreScreenshotCaptureRequest) async throws(CancellationError) -> StoreScreenshotResults
    /// 撮った元の画像を置くフォルダ（審査に出すときにここから上げる。常時オンの Mac に置き、状態リポジトリには置かない）
    func originals(_ repo: RepositoryFullName, version: MarketingVersion, commit: String) -> URL
}

/// release ブランチの先頭で App Store のスクショを撮り、配信中の版のスクショと比べる（`docs/renewal/release.md` の「スクショ」）。
/// 基準の言語を先に撮り、どれかの組に差があれば、ほかの言語もすべて撮る。差が無ければ、前に配信した版から文言が変わった言語だけを撮る。
/// 差のある画面は、見本を状態リポジトリに、元の画像を常時オンの Mac に置く
struct StoreScreenshotRun: Sendable {
    var context: CommanderContext
    var store: any AppStoreConnectSubmitting
    var capturer: any StoreScreenshotCapturing
    var sources: any ReleaseSourceReading
    var log: @Sendable (String) -> Void

    /// 撮って比べる。撮れなかったときも結果（`failed`）を返し、投げるのは取り消されたときと、待てば直るとき（App Store Connect の上限など）だけ
    func execute(
        _ file: SubmissionFile,
        commit: String,
        app: AppStoreApp,
        build: BuildSettings,
        settings: StoreScreenshotSettings
    ) async throws -> SubmissionFile.StoreScreenshots {
        let started = file.screenshots?.startedAt ?? context.timestamp
        func failed(_ message: String) -> SubmissionFile.StoreScreenshots {
            .init(state: .failed, commit: commit, startedAt: started, finishedAt: context.timestamp, failure: message)
        }
        let live: Live
        do {
            live = try await self.live(app: app, settings: settings)
        } catch let unavailable as Unavailable {
            return failed(unavailable.message)
        }
        let (current, locales) = (live.sets, live.locales)
        let liveTypes = Set(current.keys.map(\.displayType)).sorted()
        var skipped = liveTypes.filter { settings.displayTypes[$0] == nil }.map { type in
            SubmissionFile.SkippedDisplayType(displayType: type, reason: Self.unconfiguredReason)
        }
        let types = liveTypes.filter { settings.displayTypes[$0] != nil }
        guard !types.isEmpty else {
            return failed("App Store Connect にある表示サイズ（\(liveTypes.joined(separator: "・"))）の撮り方が設定に無い")
        }

        let others = locales.filter { $0 != settings.baseLocale }
        let localized = try await localizedLocales(others, file: file, commit: commit, settings: settings)

        let id = ULID.generate()
        defer { Task { await sources.release(id) } }
        let workspace: PreparedWorkspace
        do {
            workspace = try await sources.prepare(file.repo, commit: commit, for: id)
        } catch {
            throw ReleaseStepProblem("release ブランチの写しを用意できない（\(error)）", needsHuman: false)
        }
        let originals = capturer.originals(file.repo, version: file.version, commit: commit)
        var place = Place(
            request: .init(
                repo: file.repo, version: file.version, commit: commit, directory: workspace.directory, build: build, settings: settings
            ),
            comparer: .init(store: store, repo: file.repo, version: file.version, commit: commit, originals: originals),
            current: current
        )
        // 基準の言語を先に撮る。差があればほかの言語もすべて、差が無ければ文言の変わった言語だけを撮る。
        // 基準の言語を 1 組も撮れなければ、ほかの言語も撮らない（クライアントは最初の組の言語を基準の言語とみなす）
        var sets = try await shoot(types.map { StoreScreenshotTarget(displayType: $0, locale: settings.baseLocale) }, place: &place)
        if !sets.isEmpty {
            let rest = sets.contains(where: \.isChanged) ? others : localized
            let targets = types.flatMap { type in rest.map { StoreScreenshotTarget(displayType: type, locale: $0) } }
            sets += try await shoot(targets, place: &place)
        }
        skipped += place.skipped
        let previews = place.previews
        guard !sets.isEmpty else { return failed(skipped.first?.reason ?? "スクショを撮れなかった") }
        // 見本は 1 回のコミットでまとめて書く（書き込みの予算を、見本の枚数だけ使わない）
        try await StoreScreenshotComparer.writePreviews(previews, of: file, to: context.store)
        let wording = localized.isEmpty ? "" : "。文言の変わった言語 \(localized.joined(separator: "・"))"
        log("\(file.repo) の \(file.version) のスクショを撮った（差のある組 \(sets.filter(\.isChanged).count) / \(sets.count)\(wording)）")
        return .init(state: .captured, commit: commit, startedAt: started, finishedAt: context.timestamp, sets: sets, skipped: skipped)
    }

    /// `locales`（App Store Connect の言語）のうち、前に配信した版のタグから文言が変わったもの（`languages` の `language` で結ぶ）。
    /// 前の版のタグが無ければ、どれが変わったか分からないので、すべての言語を返す
    private func localizedLocales(
        _ locales: [String],
        file: SubmissionFile,
        commit: String,
        settings: StoreScreenshotSettings
    ) async throws -> [String] {
        guard !locales.isEmpty else { return [] }
        var changes = LocalizationChanges.unknown
        do {
            if let tag = try await sources.changes(file.repo, upTo: commit, below: file.version).previousTag {
                changes = try await sources.localizationChanges(file.repo, from: tag, to: commit)
            } else {
                log("\(file.repo) の \(file.version): 前に配信した版のタグが無く、文言の差を求められないので、ほかの言語もすべて撮る")
            }
        } catch {
            throw ReleaseStepProblem("前に配信した版からの文言の差を読めない（\(error)）", needsHuman: false)
        }
        return locales.filter { settings.languages[$0].map { changes.affects($0.language) } ?? false }
    }

    /// 配信中の版の、言語ごと・表示サイズごとのスクショの組と、撮る言語
    struct Live {
        var sets: [StoreScreenshotTarget: AppStoreScreenshotSet]
        var locales: [String]
    }

    /// 比べられないわけ（撮らずに `failed` にする）
    struct Unavailable: Error {
        var message: String
    }

    private func live(app: AppStoreApp, settings: StoreScreenshotSettings) async throws -> Live {
        let versions = try await call { () throws(AppStoreConnectError) in try await store.versions(of: app.id) }
        guard let live = ReleaseWatch.liveVersion(versions) else {
            throw Unavailable(message: "初めての版なので、前回の App Store のスクショが無い（App Store Connect で上げる）")
        }
        let localizations = try await call { () throws(AppStoreConnectError) in try await store.localizations(of: live.id) }
        var current: [StoreScreenshotTarget: AppStoreScreenshotSet] = [:]
        for localization in localizations where settings.languages[localization.locale] != nil {
            let sets = try await call { () throws(AppStoreConnectError) in try await store.screenshotSets(of: localization.id) }
            for set in sets { current[StoreScreenshotTarget(displayType: set.displayType, locale: localization.locale)] = set }
        }
        let locales = localizations.map(\.locale).filter { settings.languages[$0] != nil }
        guard locales.contains(settings.baseLocale) else {
            throw Unavailable(message: "配信中の版に基準の言語（\(settings.baseLocale)）の掲載文が無い")
        }
        // 配信中の版には必ずスクショがある。配置として読めないなら、比べられないので撮らない（古い API で上げたスクショは読まない）
        guard current.contains(where: { $0.key.locale == settings.baseLocale && !$0.value.screenshots.isEmpty }) else {
            throw Unavailable(
                message: "配信中の版の基準の言語（\(settings.baseLocale)）のスクショを、App Asset Library の配置として読めない（App Store Connect で確かめる）"
            )
        }
        return Live(sets: current, locales: locales)
    }

    /// 撮る頼み・比べる道具・配信中の版の組と、撮りながら集める見本（状態リポジトリのパス → base64 の文字）と撮れなかった組
    struct Place {
        var request: StoreScreenshotCaptureRequest
        var comparer: StoreScreenshotComparer
        /// 配信中の版の組
        var current: [StoreScreenshotTarget: AppStoreScreenshotSet]
        var previews: [String: String] = [:]
        var skipped: [SubmissionFile.SkippedDisplayType] = []
    }

    /// 組を撮り、配信中の版の組と比べる。差のある画面は元の画像を置き、見本を `place.previews` に足す。撮れなかった組は `place.skipped` に足す
    private func shoot(_ targets: [StoreScreenshotTarget], place: inout Place) async throws -> [SubmissionFile.ScreenshotSet] {
        guard !targets.isEmpty else { return [] }
        place.request.targets = targets
        let results = try await capturer.capture(place.request)
        var sets: [SubmissionFile.ScreenshotSet] = []
        for target in targets {
            switch results[target] {
            case let .success(shots)?:
                let compared = try await place.comparer.compare(target, shots: shots, current: place.current[target]?.screenshots ?? [])
                sets.append(compared.set)
                place.previews.merge(compared.previews) { $1 }
            case let .failure(failure)?:
                place.skipped.append(.init(displayType: target.displayType, reason: "\(target.locale): \(failure.message)"))
            case nil:
                place.skipped.append(.init(displayType: target.displayType, reason: "\(target.locale): 撮れなかった"))
            }
        }
        return sets
    }

    /// 元の画像のファイル（`<originals>/<表示サイズ>/<言語>/<位置>.png`）
    static func original(in originals: URL, target: StoreScreenshotTarget, index: Int) -> URL {
        StoreScreenshotComparer.original(in: originals, target: target, index: index)
    }

    /// 撮り方に機種の無い表示サイズのわけ
    static let unconfiguredReason = "撮り方の設定（build.storeScreenshots.displayTypes）にこの表示サイズの機種が無い"

    private func call<Value>(_ body: () async throws(AppStoreConnectError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw ReleaseWatch.problem(error)
        }
    }
}
