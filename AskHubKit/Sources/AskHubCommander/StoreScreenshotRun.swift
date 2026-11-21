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
/// 基準の言語を先に撮り、どれかの組に差があれば、ほかの言語も撮る。差のある画面は、見本を状態リポジトリに、元の画像を常時オンの Mac に置く
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

        let id = ULID.generate()
        defer { Task { await sources.release(id) } }
        let workspace: PreparedWorkspace
        do {
            workspace = try await sources.prepare(file.repo, commit: commit, for: id)
        } catch {
            throw ReleaseStepProblem("release ブランチの写しを用意できない（\(error)）", needsHuman: false)
        }
        var request = StoreScreenshotCaptureRequest(
            repo: file.repo, version: file.version, commit: commit, directory: workspace.directory, build: build, settings: settings
        )
        let place = Place(file: file, originals: capturer.originals(file.repo, version: file.version, commit: commit), current: current)
        // 基準の言語を先に撮る。差が無ければ、ほかの言語は撮らない（文言の差だけの言語ごとの撮り直しは後で足す）
        request.targets = types.map { StoreScreenshotTarget(displayType: $0, locale: settings.baseLocale) }
        var sets = try await compare(request.targets, results: try await capturer.capture(request), place: place, skipped: &skipped)
        request.targets = types.flatMap { type in
            locales.filter { $0 != settings.baseLocale }.map { StoreScreenshotTarget(displayType: type, locale: $0) }
        }
        if sets.contains(where: \.isChanged), !request.targets.isEmpty {
            sets += try await compare(request.targets, results: try await capturer.capture(request), place: place, skipped: &skipped)
        }
        guard !sets.isEmpty else { return failed(skipped.first?.reason ?? "スクショを撮れなかった") }
        log("\(file.repo) の \(file.version) のスクショを撮った（差のある組 \(sets.filter(\.isChanged).count) / \(sets.count)）")
        return .init(state: .captured, commit: commit, startedAt: started, finishedAt: context.timestamp, sets: sets, skipped: skipped)
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

    /// 比べる相手と、置く場所
    struct Place {
        var file: SubmissionFile
        /// 撮った元の画像のフォルダ（常時オンの Mac）
        var originals: URL
        /// 配信中の版の組
        var current: [StoreScreenshotTarget: AppStoreScreenshotSet]
    }

    /// 撮れた組を、配信中の版の組と比べる。差のある画面は見本と元の画像を置く。撮れなかった組は `skipped` に足す
    private func compare(
        _ targets: [StoreScreenshotTarget],
        results: StoreScreenshotResults,
        place: Place,
        skipped: inout [SubmissionFile.SkippedDisplayType]
    ) async throws -> [SubmissionFile.ScreenshotSet] {
        var sets: [SubmissionFile.ScreenshotSet] = []
        for target in targets {
            switch results[target] {
            case let .success(shots)?:
                sets.append(try await compare(target, shots: shots, place: place))
            case let .failure(failure)?:
                skipped.append(.init(displayType: target.displayType, reason: "\(target.locale): \(failure.message)"))
            case nil:
                skipped.append(.init(displayType: target.displayType, reason: "\(target.locale): 撮れなかった"))
            }
        }
        return sets
    }

    private func compare(
        _ target: StoreScreenshotTarget,
        shots: [CapturedShot],
        place: Place
    ) async throws -> SubmissionFile.ScreenshotSet {
        let current = place.current[target]?.screenshots ?? []
        var result: [SubmissionFile.Shot] = []
        for (offset, shot) in shots.enumerated() {
            let index = offset + 1
            guard let after = try? Data(contentsOf: shot.file) else {
                throw ReleaseStepProblem("撮った画像（\(target.key) の \(index) 枚目）を読めない", needsHuman: false)
            }
            let before = offset < current.count ? current[offset] : nil
            var difference = ScreenshotDifference(changed: true)
            if let before {
                if before.checksum == AppStoreScreenshot.checksum(of: after) {
                    difference = ScreenshotDifference(changed: false)
                } else if let url = before.imageURL {
                    let old = try await call { () throws(AppStoreConnectError) in try await store.downloadScreenshot(url) }
                    difference = ScreenshotDiff.compare(before: old, after: after)
                }
            }
            let url = before?.imageURL?.absoluteString
            var entry = SubmissionFile.Shot(index: index, name: shot.name, changed: difference.changed, before: url)
            if difference.changed {
                entry.area = difference.area.map(Self.area)
                entry.preview = try await keep(after, target: target, index: index, place: place)
            }
            result.append(entry)
        }
        return SubmissionFile.ScreenshotSet(
            displayType: target.displayType, locale: target.locale, shots: result, removed: max(0, current.count - shots.count)
        )
    }

    /// 差のある画面の元の画像を常時オンの Mac に、見本を状態リポジトリに置き、見本のパスを返す
    private func keep(_ data: Data, target: StoreScreenshotTarget, index: Int, place: Place) async throws -> String {
        let file = place.file
        let original = Self.original(in: place.originals, target: target, index: index)
        do {
            try FileManager.default.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: original, options: .atomic)
        } catch {
            throw ReleaseStepProblem("撮った画像を常時オンの Mac に置けない（\(error.localizedDescription)）", needsHuman: false)
        }
        guard let preview = ScreenshotDiff.preview(of: data) else {
            throw ReleaseStepProblem("撮った画像（\(target.key) の \(index) 枚目）の見本を作れない", needsHuman: false)
        }
        let path = StatePath.storeScreenshot(file.repo, file.version, displayType: target.displayType, locale: target.locale, index: index)
        do {
            let existing = try await context.store.read(path)
            _ = try await context.store.write(
                path, data: preview, replacing: existing?.sha, message: "\(file.repo) の \(file.version) のスクショの見本（\(target.key)）"
            )
        } catch {
            throw ReleaseStepProblem("スクショの見本を状態リポジトリに置けない（\(error)）", needsHuman: false)
        }
        return path
    }

    /// 元の画像のファイル（`<originals>/<表示サイズ>/<言語>/<位置>.png`）
    static func original(in originals: URL, target: StoreScreenshotTarget, index: Int) -> URL {
        originals.appendingPathComponent(target.displayType).appendingPathComponent(target.locale).appendingPathComponent("\(index).png")
    }

    /// 撮り方に機種の無い表示サイズのわけ
    static let unconfiguredReason = "撮り方の設定（build.storeScreenshots.displayTypes）にこの表示サイズの機種が無い"

    /// 変わった所（小数 4 桁）
    static func area(_ rect: CGRect) -> SubmissionFile.ChangedArea {
        func round(_ value: Double) -> Double { (value * 10_000).rounded() / 10_000 }
        return .init(x: round(rect.minX), y: round(rect.minY), width: round(rect.width), height: round(rect.height))
    }

    private func call<Value>(_ body: () async throws(AppStoreConnectError) -> Value) async throws -> Value {
        do {
            return try await body()
        } catch {
            throw ReleaseWatch.problem(error)
        }
    }
}
