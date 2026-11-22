import AskHubProtocol
import Foundation

/// 撮影のワークフローで同時に使う macOS ランナーの数（`max_parallel`。`docs/renewal/store-screenshots.md` の「撮影の並行」）。
///
/// GitHub ホストの macOS ランナーは持ち主ごとに同時 5 本で、開発の Build と分け合う。起動するときに 1 回だけ決める:
/// 同じ持ち主でほかの撮影が動いていれば 1 本、夜間で同じ持ち主の epic のジョブが無ければ 5 本、ほかは 3 本。
/// ほかの撮影は、リリースの見回りの途中で記録から覚え、epic のジョブは司令塔の周から受け取る（どちらも API と読み込みを増やさない）
extension ReleaseWatch {
    /// 決めた数と、そのわけ（ログに出す）
    struct ScreenshotParallelism: Equatable {
        var count: Int
        var reason: String
    }

    /// 夜間（`nightTimeZone` の時）。夜でも epic の CI は動くので、epic のジョブが無いときだけ 5 本にする
    static let screenshotNightHours = 0..<7
    static let screenshotNightTimeZone = TimeZone(identifier: "Asia/Tokyo") ?? .gmt
    /// `max_parallel` を受け付ける app-kit の最初の版（呼ぶ側のワークフローに無い入力を送ると、GitHub が 422 で断る）
    static let parallelScreenshotsSince = AppKitVersion(rawValue: "v1.1.0")
    /// app-kit が写す、撮影の呼ぶ側のワークフロー
    static let appKitScreenshotWorkflow = "app-store-screenshots.yml"

    /// 上から順に見て、最初に当てはまった数
    static func screenshotParallelism(otherRuns: Int, refreshed: Bool, epicJobs: Bool?, now: Date) -> ScreenshotParallelism {
        if !refreshed { return .init(count: 1, reason: "起動し直してから見回りを一周していない") }
        if otherRuns > 0 { return .init(count: 1, reason: "同じ持ち主でほかの撮影が \(otherRuns) つ動いている") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = screenshotNightTimeZone
        guard screenshotNightHours.contains(calendar.component(.hour, from: now)) else { return .init(count: 3, reason: "ふだん") }
        switch epicJobs {
        case false?: return .init(count: 5, reason: "夜間")
        case true?: return .init(count: 3, reason: "夜間だが、同じ持ち主で epic のジョブが動いている")
        case nil: return .init(count: 3, reason: "夜間だが、epic のジョブが動いているかまだ分からない")
        }
    }

    /// `max_parallel` を送ってよいリポジトリか（app-kit の v1.1.0 以上を入れ、app-kit の撮影のワークフローを起動する）
    static func acceptsMaxParallel(_ settings: RepositoryFile, workflow: StoreScreenshotWorkflow) -> Bool {
        guard workflow.workflow == appKitScreenshotWorkflow, let installed = settings.appKit?.version,
              let since = parallelScreenshotsSince else { return false }
        return installed >= since
    }

    /// 起動するリリースの数。送れないリポジトリは nil（今どおり 1 本ずつ撮る）
    func screenshotParallelism(
        for file: SubmissionFile,
        settings: RepositoryFile,
        workflow: StoreScreenshotWorkflow
    ) -> ScreenshotParallelism? {
        guard Self.acceptsMaxParallel(settings, workflow: workflow) else { return nil }
        let owner = Self.ownerKey(file.repo)
        let me = Self.screenshotKey(file)
        let others = screenshotRunsInFlight.filter { $0.key != me && $0.value == owner }.count
        return Self.screenshotParallelism(
            otherRuns: others,
            refreshed: hasRefreshedAllRepositories,
            epicJobs: ownersWithEpicJobs.map { $0.contains(owner) },
            now: context.now()
        )
    }

    /// 撮影の実行が動いている（起動して、まだ終わっていない）記録。取り込み・App Asset Library の取り込み待ちと UI テストの撮り方は、
    /// macOS のランナーを使わないので数えない
    static func isScreenshotRunInFlight(_ file: SubmissionFile) -> Bool {
        guard !file.isEnded, let shots = file.screenshots, shots.state == .capturing, let run = shots.run else { return false }
        return !run.isCompleted
    }

    /// 記録の一覧を読めたリポジトリの、撮影の実行が動いている版を覚え直す。読めなかった版（`unreadable`）は、分からないので前に覚えたものを残す
    func noteScreenshotRuns(_ repo: RepositoryFullName, files: [SubmissionFile], unreadable: Set<MarketingVersion>) {
        let prefix = "\(repo.rawValue)/"
        let kept = Set(unreadable.map { "\(repo.rawValue)/\($0.rawValue)" })
        for key in screenshotRunsInFlight.keys where key.hasPrefix(prefix) && !kept.contains(key) {
            screenshotRunsInFlight[key] = nil
        }
        for file in files where Self.isScreenshotRunInFlight(file) {
            screenshotRunsInFlight[Self.screenshotKey(file)] = Self.ownerKey(file.repo)
        }
    }

    /// 見回りの対象から外れたリポジトリの覚えたものを消す（一覧を読めた周の終わり）
    func forgetScreenshotRuns(outside repositories: [RepositoryFullName]) {
        let prefixes = repositories.map { "\($0.rawValue)/" }
        for key in screenshotRunsInFlight.keys where !prefixes.contains(where: key.hasPrefix) {
            screenshotRunsInFlight[key] = nil
        }
    }

    /// 司令塔の周が読んだ epic のジョブから、ジョブが動いている（`queued`・`assigned`・`running`）持ち主を覚える
    public func noteEpicJobs(_ jobs: [JobFile]) {
        let active: Set<JobState> = [.queued, .assigned, .running]
        ownersWithEpicJobs = Set(jobs.filter { active.contains($0.state) }.map { Self.ownerKey($0.repo) })
    }

    /// 持ち主の比べ方（GitHub の名前は大文字と小文字を区別しない）
    static func ownerKey(_ repo: RepositoryFullName) -> String {
        repo.owner.lowercased()
    }
}
