@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import AskHubPullRequests
import Foundation
import os
import Testing

/// 決まった版の app-kit を返す（本物の git は流さない）
struct FixedAppKitSource: AppKitSource {
    var release: AppKitRelease?

    func release(_ pin: AppKitFile.Pin) async throws(AppKitSourceError) -> AppKitRelease {
        guard let release, release.pin == pin else { throw .malformed("版 \(pin.version) が無い") }
        return release
    }
}

/// app-kit への入れ替えの中身（`AppKitAdoptionPlanner`）と、app-kit を git で読む部品
struct AppKitAdoptionTests {
    static let ref = String(repeating: "a", count: 40)
    static let pin = AppKitFile.Pin(version: AppKitVersion(rawValue: "v1.0.0")!, ref: ref)
    static let callerBuild = """
        name: Build
        on:
          push:
            branches: ['**']
        jobs:
          build:
            uses: shilokuma-inc/app-kit/.github/workflows/app-build.yml@{{APP_KIT_REF}} # {{APP_KIT_VERSION}}
            with:
              app-kit-ref: '{{APP_KIT_REF}}'
        """

    static var release: AppKitRelease {
        let manifest = AppKitManifest(
            managed: [".coderabbit.yaml", ".github/workflows/build.yml", ".swiftlint.yml"],
            replaces: [
                .init(path: ".github/workflows/_build.yml"),
                .init(path: ".github/workflows/_archive.yml"),
                .init(path: ".github/workflows/build-develop.yml"),
                .init(path: ".github/scripts/check-app-store-app.rb"),
                .init(path: "Tools/app_store_config.py", keepIfPresent: ["Tools/upload_creative_assets.py"])
            ]
        )
        return AppKitRelease(
            pin: pin,
            manifest: manifest,
            managed: [
                ".coderabbit.yaml": "reviews: {}\n",
                ".github/workflows/build.yml": AppKitRelease.render(callerBuild, pin: pin),
                ".swiftlint.yml": "line_length: 140\n"
            ],
            steps: ["Checkout", "Select Xcode", "Archive"],
            buildJobs: ["build"]
        )
    }

    static func file(_ path: String, _ text: String? = nil) -> TreeFile {
        TreeFile(path: path, mode: "100644", type: "blob", sha: text.map(GitBlob.sha(of:)) ?? String(repeating: "f", count: 40))
    }

    static let archive = """
        name: Archive
        jobs:
          archive:
            steps:
              - name: Checkout
                uses: actions/checkout@v7
              - name: "Write GoogleService-Info.plist" # Secret から書き出す
                run: echo "$GOOGLE_SERVICE_INFO_PLIST_BASE64" | base64 -d > Kobosu/GoogleService-Info.plist
              - name: Archive
                run: xcodebuild archive
        """

    static func build(childChecks: [String] = ["build / build"]) throws -> RepositoryFile.Build {
        try RepositoryFile.Build(
            xcode: BuildSettings(
                project: "Kobosu.xcodeproj",
                scheme: "Kobosu",
                destinations: [.simulator(.init(platform: .iOS, deviceType: "iPhone 17 Pro")), .macOS]
            ),
            childChecks: childChecks,
            finalChecks: childChecks
        )
    }

    // MARK: - 入れ替えの中身

    @Test func replacesManagedFilesWritesConfigAndRemovesReplacedFiles() throws {
        let files = [
            Self.file(".coderabbit.yaml", "reviews: {}\n"),
            Self.file(".github/workflows/build.yml", "name: Build\n"),
            Self.file(".github/workflows/_build.yml"),
            Self.file(".github/workflows/_archive.yml"),
            Self.file(".github/scripts/check-app-store-app.rb"),
            Self.file("Tools/app_store_config.py"),
            Self.file("Tools/upload_creative_assets.py"),
            Self.file("KobosuUITests/KobosuUITests.swift"),
            Self.file("OtherUITests/OtherUITests.swift")
        ]
        let texts = [".github/workflows/_archive.yml": Self.archive, ".github/scripts/check-app-store-app.rb": "a\nb\nc\n"]
        let plan = AppKitAdoptionPlanner.plan(
            release: Self.release, files: files, texts: texts, build: try Self.build(), waitedChecks: ["build / build"]
        )
        #expect(plan.problems.isEmpty)
        #expect(plan.adoption == AppKitAdoption(version: Self.pin.version, ref: Self.ref))
        #expect(plan.summary == [
            .init(kind: .adoptAppKit, path: ".github/app-kit.json"),
            // 中身が同じ .coderabbit.yaml は変えない
            .init(kind: .adoptAppKit, path: ".github/workflows/build.yml"),
            .init(kind: .adoptAppKit, path: ".swiftlint.yml"),
            .init(kind: .removeReplaced, path: ".github/workflows/_build.yml"),
            .init(kind: .removeReplaced, path: ".github/workflows/_archive.yml", lines: 10, steps: ["Write GoogleService-Info.plist"]),
            .init(kind: .removeReplaced, path: ".github/scripts/check-app-store-app.rb", lines: 3)
        ])
        // クリエイティブ素材の道具があるので、app_store_config.py は残す
        #expect(plan.changes["Tools/app_store_config.py"] == nil)
        #expect(plan.changes[".github/workflows/_build.yml"] == .some(nil))
        let build: String?? = plan.changes[".github/workflows/build.yml"]
        #expect(build??.contains("app-build.yml@\(Self.ref) # v1.0.0") == true)
        #expect(build??.contains("app-kit-ref: '\(Self.ref)'") == true)
        let config: String?? = plan.changes[AppKitPolicy.configPath]
        #expect(config == .some("""
            {
              "v": 1,
              "project": "Kobosu.xcodeproj",
              "scheme": "Kobosu",
              "platforms": ["iOS", "macOS"],
              "uiTests": "KobosuUITests",
              "archive": { "googleServiceInfo": "Kobosu/GoogleService-Info.plist" }
            }

            """))
    }

    /// `.github/app-kit.json` が既にあれば変えず、`unmanaged` のファイルは写さない
    @Test func keepsExistingConfigAndUnmanagedFiles() throws {
        let files = [Self.file(AppKitPolicy.configPath), Self.file(".coderabbit.yaml", "mine\n")]
        let config = #"{"v":1,"project":"A.xcodeproj","scheme":"A","platforms":["iOS"],"unmanaged":[".coderabbit.yaml"]}"#
        let texts = [AppKitPolicy.configPath: config]
        let plan = AppKitAdoptionPlanner.plan(
            release: Self.release, files: files, texts: texts, build: nil, waitedChecks: ["build / build"]
        )
        #expect(plan.summary.map(\.path) == [".github/workflows/build.yml", ".swiftlint.yml"])
        #expect(plan.changes[".coderabbit.yaml"] == nil)
    }

    /// 入れ替えた後に出ない待つチェック（古い 3 本立ての Build など）は、入れ替えた後の名前に付け替える
    @Test func renamesChecksThatDisappear() throws {
        let files = [Self.file(".github/workflows/build-develop.yml")]
        let plan = AppKitAdoptionPlanner.plan(
            release: Self.release, files: files, texts: [:], build: try Self.build(childChecks: ["Build"]), waitedChecks: ["Build", "Build"]
        )
        #expect(plan.adoption?.renamedChecks == [CheckRename(from: "Build", to: "build / build")])
        #expect(AppKitAdoptionPlanner.renaming(["Build", "build / build", "lint"], with: [.init(from: "Build", to: "build / build")])
            == ["build / build", "lint"])
        // 入れ替えた後のチェックが 1 つに決まらなければ、入れ替えない
        let unclear = AppKitAdoptionPlanner.renamedChecks(["Build"], produced: [])
        #expect((try? unclear.get()) == nil)
        #expect(try AppKitAdoptionPlanner.renamedChecks(["build / build"], produced: ["build / build"]).get().isEmpty)
    }

    @Test func refusesWithoutBuildSettingsOrWithWorkspace() throws {
        let plan = AppKitAdoptionPlanner.plan(release: Self.release, files: [], texts: [:], build: nil, waitedChecks: [])
        #expect(plan.problems == ["ビルドの設定が無いので、app-kit の設定（.github/app-kit.json）を作れない。先にビルドの設定を入れる"])
        #expect(plan.changes.isEmpty && plan.adoption == nil)
        let workspace = try RepositoryFile.Build(
            xcode: BuildSettings(project: "App.xcworkspace", scheme: "App", destinations: [.macOS]),
            childChecks: ["build / build"],
            finalChecks: ["build / build"]
        )
        let refused = AppKitAdoptionPlanner.plan(release: Self.release, files: [], texts: [:], build: workspace, waitedChecks: [])
        #expect(refused.problems == ["ビルドの設定のプロジェクト App.xcworkspace が .xcodeproj でないので、app-kit に入れ替えられない"])
    }

    /// もう版の中身と同じなら、何も変えない
    @Test func changesNothingWhenAlreadyTheSame() throws {
        let release = Self.release
        let files = [Self.file(AppKitPolicy.configPath)] + release.manifest.managed.map { Self.file($0, release.managed[$0]) }
        let plan = AppKitAdoptionPlanner.plan(release: release, files: files, texts: [:], build: nil, waitedChecks: ["build / build"])
        #expect(plan == AppKitAdoptionPlanner.Plan())
    }

    @Test func readsCallerRefAndReleaseShapes() throws {
        let rendered = AppKitRelease.render(Self.callerBuild, pin: Self.pin)
        #expect(AppKitCaller.ref(in: [WorkflowFile(path: ".github/workflows/build.yml", text: rendered)]) == Self.ref)
        #expect(AppKitCaller.ref(in: [WorkflowFile(path: ".github/workflows/build.yml", text: Self.callerBuild)]) == nil)
        #expect(AppKitCaller.ref(in: [WorkflowFile(path: ".github/workflows/other.yml", text: rendered)]) == nil)
        #expect(Self.release.buildChecks == ["build / build"])
        // git hash-object と同じ
        #expect(GitBlob.sha(of: "hello\n") == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(WorkflowSteps.names(in: Self.archive) == ["Checkout", "Write GoogleService-Info.plist", "Archive"])
        #expect(AppKitAdoptionPlanner.lineCount("") == 0)
        #expect(AppKitAdoptionPlanner.lineCount("a\nb") == 2)
        #expect(!AppKitManifest(managed: ["../x"], replaces: []).problems.isEmpty)
        #expect(!AppKitManifest(managed: [".git/config"], replaces: []).problems.isEmpty)
        #expect(!AppKitManifest(managed: ["a"], replaces: [.init(path: "a")]).problems.isEmpty)
        let manifest = AppKitManifest(managed: [".github/workflows/build.yml"], replaces: [.init(path: "Tools/a.py", keepIfPresent: ["b"])])
        #expect(manifest.problems.isEmpty)
    }

    // MARK: - git で読む

    /// 版のコミットを浅く取り、manifest と写すファイルを読む。同じ版は読み直さない
    @Test func gitSourceReadsReleaseOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppKitSource-\(UUID().uuidString)/app-kit.git")
        defer { try? FileManager.default.removeItem(at: directory.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("ref: refs/heads/main\n".utf8).write(to: directory.appendingPathComponent("HEAD"))
        let manifest = #"{"v":1,"managed":[".github/workflows/build.yml"],"replaces":[{"path":".github/workflows/_build.yml"}]}"#
        let git = AppKitGit([
            "cat-file": .init(status: 1, standardOutput: Data(), standardError: Data()),
            "fetch": Self.output(""),
            "show \(Self.ref):manifest.json": Self.output(manifest),
            "show \(Self.ref):managed/.github/workflows/build.yml": Self.output(Self.callerBuild),
            "ls-tree": Self.output(".github/workflows/app-build.yml\n.github/workflows/self-test.yml\n"),
            "show \(Self.ref):.github/workflows/app-build.yml": Self.output("jobs:\n  build:\n    steps:\n      - name: Checkout\n")
        ])
        let source = GitAppKitSource(setup: .init(directory: directory), runner: git)
        let release = try await source.release(Self.pin)
        #expect(release.managed[".github/workflows/build.yml"]?.contains("@\(Self.ref) # v1.0.0") == true)
        #expect(release.manifest.replaces == [.init(path: ".github/workflows/_build.yml")])
        #expect(release.steps == ["Checkout"])
        #expect(release.buildChecks == ["build / build"])
        let fetch = try #require(git.commands.first { $0.arguments.contains("fetch") })
        #expect(fetch.arguments.suffix(2) == ["https://github.com/shilokuma-inc/app-kit.git", Self.ref])
        #expect(fetch.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        let count = git.commands.count
        _ = try await source.release(Self.pin)
        #expect(git.commands.count == count)
        // 形の違うコミットは git に渡さない
        await #expect(throws: AppKitSourceError.self) {
            try await source.release(.init(version: Self.pin.version, ref: "main"))
        }
    }

    static func output(_ text: String) -> CommandResult {
        CommandResult(status: 0, standardOutput: Data(text.utf8), standardError: Data())
    }
}

/// git の引数（`--git-dir` の後ろ）の先頭の 2 つか 1 つで、決まった結果を返す
final class AppKitGit: CommandRunning {
    private let state: OSAllocatedUnfairLock<[Command]>
    let results: [String: CommandResult]

    init(_ results: [String: CommandResult]) {
        self.results = results
        state = OSAllocatedUnfairLock(initialState: [])
    }

    var commands: [Command] { state.withLock { $0 } }

    func run(_ command: Command) async throws -> CommandResult {
        state.withLock { $0.append(command) }
        let arguments = Array(command.arguments.drop { $0 != "--git-dir" }.dropFirst(2))
        let two = arguments.prefix(2).joined(separator: " ")
        let failure = CommandResult(status: 128, standardOutput: Data(), standardError: Data("fatal: \(two)".utf8))
        return results[two] ?? results[arguments.first ?? ""] ?? failure
    }
}
