import Foundation

// MARK: - app-kit

extension DemoData {
    static let appKitLatest = "v1.1.0"
    static let appKitPrevious = "v1.0.1"
    private static let appKitRefs = [appKitLatest: String(repeating: "b", count: 40), appKitPrevious: String(repeating: "a", count: 40)]

    /// 習慣ログを試しの 1 本にして v1.1.0 を広げ終わった様子。積読リストは写すファイルがずれている
    func appKit() -> AppKitOverview {
        let skipped = "まだ app-kit に入れ替えていない（リポジトリの画面の「準備をやり直す」で入れ替える）"
        let targets: [AppKitOverview.Target] = [
            target("demo-studio/habit-ios", .done, pullRequest: 31, minutes: 300),
            target("demo-studio/pocket-budget-ios", .done, pullRequest: 12, minutes: 280),
            target("demo-studio/rain-ios", .done, pullRequest: 27, minutes: 270),
            target("demo-studio/recipe-apple", .done, pullRequest: 58, minutes: 260),
            target("kurashi-apps/kaji-share-ios", .skipped, problem: skipped, minutes: 250),
            target("kurashi-apps/tsundoku-ios", .done, minutes: 250),
            target("shilokuma-inc/template-app-ios", .done, pullRequest: 201, minutes: 240, isTemplate: true)
        ]
        let latest = Self.appKitLatest
        let changes = "- visionOS のスクショを撮れるようにした\n- Upload で TestFlight の内部テスターを足す手順を直した\n- Xcode の既定を 26.6 にした"
        return AppKitOverview(
            checkedAt: ago(minutes: 20),
            releases: [
                .init(version: latest, ref: Self.appKitRefs[latest] ?? "", changes: changes, foundAt: ago(minutes: 60 * 26)),
                .init(
                    version: Self.appKitPrevious,
                    ref: Self.appKitRefs[Self.appKitPrevious] ?? "",
                    changes: "- 撮影の Dynamic Island を重ねる道具の直し",
                    foundAt: ago(minutes: 60 * 24 * 3)
                )
            ],
            adoptionVersion: latest,
            rollout: .init(
                version: latest,
                ref: Self.appKitRefs[latest] ?? "",
                state: .finished,
                pilot: "demo-studio/habit-ios",
                targets: targets,
                startedAt: ago(minutes: 310),
                updatedAt: ago(minutes: 240)
            ),
            templates: [
                .init(repository: "shilokuma-inc/template-app-ios", installed: installation(latest, minutes: 240)),
                .init(repository: "shilokuma-vision/template-app-visionos", installed: nil)
            ]
        )
    }

    /// v1.1.0 を広げ終わった後に、変更点の長い v1.2.0 が出た様子
    func appKitWithNewRelease() -> AppKitOverview {
        var overview = appKit()
        let changes = """
            ## 足したこと
            - visionOS のスクショで、没入型の空間を撮れるようにした
            - Upload で、TestFlight の外部テスターのグループにも配れるようにした
            - 撮影の設定に、ダークの外観を足した
            ## 変えたこと
            - SwiftLint の版を上げ、CI では --strict で流すようにした
            - Build のキャッシュの鍵に Package.resolved を含めた
            - What's New の文字数を、審査に出す前に確かめるようにした
            ## 直したこと
            - Simulator の向きが横のまま残ると、撮影が崩れる不具合を直した
            - release ブランチの Upload が、ビルド番号を重ねることがある不具合を直した
            """
        let ref = String(repeating: "c", count: 40)
        overview.releases.insert(AppKitOverview.Release(version: "v1.2.0", ref: ref, changes: changes, foundAt: ago(minutes: 180)), at: 0)
        return overview
    }

    private func target(
        _ repository: String,
        _ state: AppKitTargetState,
        pullRequest: Int? = nil,
        problem: String? = nil,
        minutes: Double,
        isTemplate: Bool = false
    ) -> AppKitOverview.Target {
        .init(
            repository: repository,
            isTemplate: isTemplate,
            state: state,
            pullRequest: pullRequest,
            problem: problem,
            updatedAt: ago(minutes: minutes)
        )
    }

    /// 入れ替え済みのリポジトリに、入っている版と広げた版の様子を付ける
    func withAppKit(_ repository: TargetRepository) -> TargetRepository {
        var repository = repository
        let target = appKit().rollout?.targets.first { $0.id == repository.id }
        var installed = installation(Self.appKitLatest, minutes: target.map { -$0.updatedAt.timeIntervalSince(now) / 60 } ?? 240)
        if repository.name == "tsundoku-ios" {
            installed.drift = [".swiftlint.yml が app-kit v1.1.0 の中身と違う"]
            installed.driftFoundAt = ago(minutes: 90)
        }
        repository.appKit = RepositoryAppKit(installed: installed, rolloutVersion: Self.appKitLatest, rolloutTarget: target)
        return repository
    }

    private func installation(_ version: String, minutes: Double) -> AppKitInstallation {
        AppKitInstallation(version: version, ref: Self.appKitRefs[version] ?? "", installedAt: ago(minutes: minutes))
    }
}
