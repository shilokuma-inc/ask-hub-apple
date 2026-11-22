import AskHubBuild
import AskHubProtocol
import Foundation

/// 常時オンの Mac で App Store のスクショを撮る（`StoreScreenshotCapturing` の本物）。
/// ジョブと同じビルドの枠（`BuildSlots`）を 1 つ借り、枠の Simulator（`SimulatorPool`）を表示サイズの機種ごとに用意して、
/// テストのビルドは 1 回だけにし、組ごとに UI テストを流す。DerivedData・結果・元の画像は、この Mac の `root` の下に置く
public struct MachineStoreScreenshots: StoreScreenshotCapturing {
    public var pool: SimulatorPool
    public var slots: BuildSlots
    public var root: URL
    public var log: @Sendable (String) -> Void

    public init(pool: SimulatorPool, slots: BuildSlots, root: URL, log: @escaping @Sendable (String) -> Void) {
        self.pool = pool
        self.slots = slots
        self.root = root
        self.log = log
    }

    public func capture(_ request: StoreScreenshotCaptureRequest) async throws(CancellationError) -> StoreScreenshotResults {
        let results = await slots.withSlot { slot in await capture(request, slot: slot) }
        if Task.isCancelled { throw CancellationError() }
        return results
    }

    public func originals(_ repo: RepositoryFullName, version: MarketingVersion, commit: String) -> URL {
        directory(repo, version).appendingPathComponent("originals/\(commit)", isDirectory: true)
    }

    private func directory(_ repo: RepositoryFullName, _ version: MarketingVersion) -> URL {
        root.appendingPathComponent("\(repo.owner)/\(repo.name)/\(version.rawValue)", isDirectory: true)
    }

    private func capture(_ request: StoreScreenshotCaptureRequest, slot: Int) async -> StoreScreenshotResults {
        let capturer = StoreScreenshotCapturer(tools: pool.tools, runner: pool.runner)
        let base = directory(request.repo, request.version)
        let derivedData = base.appendingPathComponent("DerivedData", isDirectory: true)
        var results: StoreScreenshotResults = [:]
        var built = false
        // 表示サイズごとに Simulator を用意し、その中で言語ごとに流す（並びは頼まれた順）
        var types: [String] = []
        for target in request.targets where !types.contains(target.displayType) { types.append(target.displayType) }
        do {
            for type in types {
                let targets = request.targets.filter { $0.displayType == type }
                let simulator: Simulator
                switch await prepareSimulator(for: request.settings.displayTypes[type] ?? [], slot: slot) {
                case let .success(prepared):
                    simulator = prepared
                case let .failure(failure):
                    for target in targets { results[target] = .failure(failure) }
                    continue
                }
                if !built {
                    if let problem = try await capturer.buildForTesting(
                        request.build, sourceDirectory: request.directory, derivedData: derivedData, on: simulator
                    ) {
                        for target in request.targets where results[target] == nil { results[target] = .failure(CaptureFailure(problem)) }
                        return results
                    }
                    built = true
                }
                results.merge(try await run(targets, of: request, with: capturer, on: simulator)) { $1 }
            }
        } catch {
            for target in request.targets where results[target] == nil { results[target] = .failure(CaptureFailure("取り消された")) }
        }
        return results
    }

    /// 1 つの表示サイズの Simulator で、言語ごとに UI テストを流す
    private func run(
        _ targets: [StoreScreenshotTarget],
        of request: StoreScreenshotCaptureRequest,
        with capturer: StoreScreenshotCapturer,
        on simulator: Simulator
    ) async throws(CancellationError) -> StoreScreenshotResults {
        let base = directory(request.repo, request.version)
        let derivedData = base.appendingPathComponent("DerivedData", isDirectory: true)
        var results: StoreScreenshotResults = [:]
        for target in targets {
            let run = StoreScreenshotCapturer.Run(
                settings: request.build,
                test: request.settings.test,
                environment: Self.environment(request.settings, locale: target.locale),
                sourceDirectory: request.directory,
                derivedData: derivedData,
                output: base.appendingPathComponent("runs/\(request.commit)/\(target.key)", isDirectory: true)
            )
            results[target] = try await capturer.run(run, on: simulator)
            log("\(request.repo) の \(request.version) のスクショ（\(target.displayType)/\(target.locale)）を撮った")
        }
        return results
    }

    /// 機種の候補から、用意できた最初の Simulator。どれも用意できなければ、最後の候補の理由
    /// （新しい機種は、対応するランタイムと Xcode が要る。iPhone Duo は iOS 27.1 と Xcode 27.1 以上）
    private func prepareSimulator(for devices: [String], slot: Int) async -> Result<Simulator, CaptureFailure> {
        var reason = "機種の候補が無い"
        for device in devices {
            do {
                let destination = SimulatorDestination(platform: .iOS, deviceType: device)
                return .success(try await pool.prepare(slot: slot, for: destination, restarting: true))
            } catch {
                log("スクショの Simulator（\(device)）を用意できない（\(error.message)）")
                reason = "\(device): \(error.message)"
            }
        }
        return .failure(CaptureFailure("Simulator を用意できない（\(reason)）"))
    }

    /// 組のテストに渡す環境変数（決まった値と、言語・地域）
    static func environment(_ settings: StoreScreenshotSettings, locale: String) -> [String: String] {
        var environment = settings.environment
        guard let language = settings.languages[locale] else { return environment }
        environment[settings.languageVariable] = language.language
        if let variable = settings.regionVariable, let region = language.region { environment[variable] = region }
        return environment
    }
}
