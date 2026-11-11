@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

struct XcodeBuildRunnerTests {
    static let epic = ULID(rawValue: "01JC0000000000000000000000")!
    static let simulator = Simulator(
        udid: "BC2BD4B7-3E0A-4630-849B-531089F0A006",
        name: "askhub-worker-1-iPhone-17-Pro-iOS-26.5",
        runtime: "com.apple.CoreSimulator.SimRuntime.iOS-26-5",
        state: "Booted"
    )
    static let source = URL(fileURLWithPath: "/Users/me/Library/AskHub/jobs/01JC/repository/App")
    static let token = "github_pat_" + String(repeating: "d", count: 40)

    static func settings() throws -> BuildSettings {
        try BuildSettings(
            project: "App.xcodeproj",
            scheme: "App",
            destinations: [.simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro")), .macOS],
            testLight: TestSelection(onlyTesting: ["AppTests"]),
            testFull: TestSelection(testPlan: "Full", skipTesting: ["AppUITests/LaunchTests"])
        )
    }

    /// 一時フォルダを置き場所にした runner。`xcodebuild` は `respond` の結果を返し、`bundle` なら結果のバンドルのフォルダを作る。
    /// `xcresulttool` は `build`・`tests` の JSON を返す（nil なら失敗）
    private func makeRunner(
        bundle: Bool = true,
        build: String? = nil,
        tests: String? = nil,
        respond: @escaping @Sendable (Command) -> CommandResult
    ) -> (XcodeBuildRunner, FakeCommands) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-build-tests-\(UUID().uuidString)")
        let fake = FakeCommands { command in
            let arguments = command.arguments
            switch arguments.prefix(3) {
            case ["xcresulttool", "get", "build-results"]:
                return build.map(CommandResult.output) ?? .failure(1, "")
            case ["xcresulttool", "get", "test-results"]:
                return tests.map(CommandResult.output) ?? .failure(1, "")
            default:
                if bundle, let index = arguments.firstIndex(of: "-resultBundlePath") {
                    try? FileManager.default.createDirectory(atPath: arguments[index + 1], withIntermediateDirectories: true)
                }
                return respond(command)
            }
        }
        let tools = BuildTools(home: URL(fileURLWithPath: "/Users/me"), temporaryDirectory: root.appendingPathComponent("tmp"))
        return (XcodeBuildRunner(tools: tools, directories: BuildDirectories(root: root), runner: fake), fake)
    }

    private func request(_ kind: BuildKind, on destination: PreparedDestination = .simulator(simulator)) throws -> BuildRequest {
        BuildRequest(settings: try Self.settings(), kind: kind, destination: destination, sourceDirectory: Self.source, epic: Self.epic)
    }

    /// `option` の次の引数
    private func value(after option: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: option).flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil }
    }

    // MARK: - 引数

    @Test func buildsTestArgumentsForTheSimulator() throws {
        let directories = BuildDirectories(root: URL(fileURLWithPath: "/w/builds"))
        let request = try request(.testLight)
        let bundle = directories.resultBundle(for: Self.epic, named: XcodeBuildRunner.bundleName(for: request))
        #expect(bundle.lastPathComponent == "testLight-askhub-worker-1-iPhone-17-Pro-iOS-26.5.xcresult")
        #expect(bundle.deletingLastPathComponent().path == "/w/builds/01JC0000000000000000000000/results")
        let arguments = XcodeBuildRunner.arguments(for: request, derivedData: directories.derivedData(for: Self.epic), resultBundle: bundle)
        #expect(arguments == [
            "xcodebuild", "test", "-project", "App.xcodeproj", "-scheme", "App",
            "-destination", "id=BC2BD4B7-3E0A-4630-849B-531089F0A006",
            "-derivedDataPath", "/w/builds/01JC0000000000000000000000/DerivedData",
            "-resultBundlePath", bundle.path,
            "-skipPackagePluginValidation", "-skipMacroValidation",
            "-parallel-testing-enabled", "NO", "-collect-test-diagnostics", "never", "-only-testing:AppTests",
            "COMPILER_INDEX_STORE_ENABLE=NO"
        ])
    }

    @Test func buildsArgumentsForTheFinalTestsAndMacOS() throws {
        var request = try request(.testFull, on: .macOS)
        let derivedData = URL(fileURLWithPath: "/d")
        let bundle = URL(fileURLWithPath: "/r")
        let arguments = XcodeBuildRunner.arguments(for: request, derivedData: derivedData, resultBundle: bundle)
        #expect(value(after: "-destination", in: arguments) == "platform=macOS")
        #expect(value(after: "-testPlan", in: arguments) == "Full")
        #expect(arguments.contains("-skip-testing:AppUITests/LaunchTests"))
        #expect(!arguments.contains("-only-testing:AppTests"))
        // 全部のテスト・macOS でも、落ちたテストの後に診断を集めて止まらない
        #expect(value(after: "-collect-test-diagnostics", in: arguments) == "never")
        // macOS はアドホック署名
        #expect(arguments.suffix(4) == [
            "CODE_SIGN_IDENTITY=-", "CODE_SIGN_STYLE=Manual", "DEVELOPMENT_TEAM=", "PROVISIONING_PROFILE_SPECIFIER="
        ])
        #expect(XcodeBuildRunner.bundleName(for: request) == "testFull-macOS")

        request.kind = .build
        request.settings.project = "App.xcworkspace"
        let build = XcodeBuildRunner.arguments(for: request, derivedData: derivedData, resultBundle: bundle)
        #expect(build.prefix(4) == ["xcodebuild", "build", "-workspace", "App.xcworkspace"])
        #expect(!build.contains("-parallel-testing-enabled"))
        #expect(!build.contains("-collect-test-diagnostics"))
        #expect(!build.contains("-testPlan"))
    }

    // MARK: - 流す

    @Test func runsInTheCheckoutWithAFreshEnvironmentAndReplacesTheOldBundle() async throws {
        let (runner, fake) = makeRunner(build: Fixtures.noErrors, tests: Fixtures.passedSummary) { _ in .output("** TEST SUCCEEDED **\n") }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let request = try request(.testLight)
        let old = runner.directories.resultBundle(for: Self.epic, named: XcodeBuildRunner.bundleName(for: request))
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: old.appendingPathComponent("old").path, contents: Data())

        let outcome = try await runner.run(request, timeout: .seconds(600))
        #expect(outcome.succeeded)
        #expect(outcome.summary == "テストが通った（全 2 件）")
        #expect(outcome.report.tests == TestCounts(total: 2, passed: 2, failed: 0, skipped: 0))
        #expect(outcome.resultBundle == old)
        #expect(!FileManager.default.fileExists(atPath: old.appendingPathComponent("old").path))

        let xcodebuild = try #require(fake.commands.first)
        #expect(xcodebuild.executable.path == "/usr/bin/xcrun")
        #expect(xcodebuild.workingDirectory == Self.source)
        #expect(xcodebuild.timeout == .seconds(600))
        #expect(xcodebuild.environment == runner.tools.environment)
        for name in ["GITHUB_TOKEN", "GH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY", "SSH_AUTH_SOCK"] {
            #expect(xcodebuild.environment[name] == nil)
        }
        #expect(fake.arguments.dropFirst().map { Array($0.prefix(3)) } == [
            ["xcresulttool", "get", "build-results"], ["xcresulttool", "get", "test-results"]
        ])
    }

    @Test func summarizesFailedTestsWithoutSecretsOrLocalPaths() async throws {
        let summary = Fixtures.failedSummary(token: Self.token)
        let (runner, _) = makeRunner(build: Fixtures.noErrors, tests: summary) { _ in
            .failure(65, "Testing failed:\n\tadds() failed\n** TEST FAILED **\n")
        }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let outcome = try await runner.run(try request(.testLight), timeout: .seconds(600))
        #expect(outcome.failure == .test)
        #expect(outcome.summary == "テストが落ちた（2 件 / 全 2 件）")
        #expect(outcome.report.failedTests.map(\.name) == ["ProbeTests/AdditionTests/adds()", "ProbeTests/LegacyTests/testAdds()"])
        let text = outcome.report.text()
        #expect(!text.contains(Self.token))
        #expect(text.contains("<伏せた>"))
        #expect(text.contains("- ProbeTests/LegacyTests/testAdds(): XCTAssertEqual failed: (\"4\") is not equal to (\"5\")"))
        #expect(outcome.report.log == nil)
        #expect(outcome.attemptFailure?.failureClass == .testFailed)
    }

    @Test func summarizesBuildErrors() async throws {
        let (runner, _) = makeRunner(build: Fixtures.buildErrors(source: Self.source.path)) { _ in
            .failure(65, "\(Self.source.path)/Probe/ProbeApp.swift:10:48: error: cannot find 'missing' in scope\n** TEST FAILED **\n")
        }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let outcome = try await runner.run(try request(.testLight), timeout: .seconds(600))
        #expect(outcome.failure == .build)
        #expect(outcome.summary == "ビルドが通らない（エラー 1 件）")
        // 「ビルドが失敗したのでテストを取り消した」は除き、場所は写しからの相対パスと 1 から数えた行にする
        #expect(outcome.report.errors == [BuildIssue(message: "Cannot find 'missing' in scope", location: "Probe/ProbeApp.swift:10")])
        #expect(outcome.report.text() == "ビルドのエラー（1 件）\n- Probe/ProbeApp.swift:10 Cannot find 'missing' in scope")
        #expect(outcome.attemptFailure?.failureClass == .buildFailed)
    }

    @Test(arguments: [
        (CommandResult(status: 15, terminatedBySignal: true, standardOutput: Data(), standardError: Data(), timedOut: true), .timeout),
        (.failure(70, "xcodebuild: error: Unable to find a device matching the provided destination specifier:\n{ id:B }"), .environment),
        (.failure(65, "DTServiceHubClient failed to bless service hub\n** BUILD INTERRUPTED **"), .environment),
        (.failure(65, "Test runner never began executing tests after launching."), .environment),
        (.failure(65, "IDELaunchReport: Finished with error: Simulator device failed to launch com.example.App."), .environment),
        (.failure(74, "xcodebuild: error: Could not resolve package dependencies:\n  Could not resolve host: github.com"), .environment),
        (.failure(65, "/w/App/Foo.swift:3:5: error: cannot find 'x' in scope\n** TEST FAILED **"), .build),
        (.failure(65, "ld: symbol(s) not found\nclang: error: linker command failed with exit code 1"), .build),
        (.failure(65, "Testing failed:\n** TEST FAILED **"), .test),
        (.failure(66, "xcodebuild: error: The project named \"App\" does not contain a scheme named \"App\"."), .unknown)
    ] as [(CommandResult, BuildFailureKind)])
    func classifiesFailuresWithoutAResultBundle(result: CommandResult, kind: BuildFailureKind) async throws {
        let (runner, _) = makeRunner(bundle: false) { _ in result }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let outcome = try await runner.run(try request(.testLight), timeout: .seconds(600))
        #expect(outcome.failure == kind)
        #expect(outcome.resultBundle == nil)
        // 理由はエラーの行から読めるようにする（時間切れは出力が無いことがある）
        #expect(outcome.report.log?.isEmpty == false || kind == .timeout)
    }

    @Test func explainsUnknownFailures() async throws {
        let (runner, _) = makeRunner(bundle: false) { _ in
            .failure(66, "xcodebuild: error: The project named \"App\" does not contain a scheme named \"Other\".")
        }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let outcome = try await runner.run(try request(.build), timeout: .seconds(600))
        #expect(outcome.summary == "xcodebuild が失敗した（終了コード 66）: "
            + "xcodebuild: error: The project named \"App\" does not contain a scheme named \"Other\".")
        #expect(outcome.attemptFailure?.failureClass == .unexpected)
    }

    @Test func treatsLaunchFailuresAsEnvironmentProblems() async throws {
        struct LaunchFailure: Error {}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-build-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = BuildTools(temporaryDirectory: root)
        let directories = BuildDirectories(root: root)
        let failing = XcodeBuildRunner(tools: tools, directories: directories, runner: FailingRunner(error: LaunchFailure()))
        let outcome = try await failing.run(try request(.build), timeout: .seconds(600))
        #expect(outcome.failure == .environment)

        let cancelled = XcodeBuildRunner(tools: tools, directories: directories, runner: FailingRunner(error: CancellationError()))
        let request = try request(.build)
        await #expect(throws: CancellationError.self) { try await cancelled.run(request, timeout: .seconds(600)) }
    }

    // MARK: - アプリかテストの実行役を起動できなかった

    /// 2026-11-10 に Mac mini で起きた形（入れたアプリを起動できない・実行役がつながる前に固まる）
    @Test(arguments: [
        (Fixtures.launchFailureBuild, Fixtures.launchFailureSummary),
        (Fixtures.hungBuild, Fixtures.hungSummary)
    ])
    func marksLaunchFailures(build: String, tests: String) async throws {
        let (runner, _) = makeRunner(build: build, tests: tests) { _ in
            .failure(65, "Testing failed:\n\tencountered an error\n** TEST FAILED **\n")
        }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let outcome = try await runner.run(try request(.testLight), timeout: .seconds(600))
        #expect(outcome.failure == .environment)
        #expect(outcome.launchFailed)
        #expect(outcome.summary == "Simulator か Xcode の不調でビルドとテストを流せない")
        #expect(outcome.attemptFailure?.failureClass == .unexpected)
    }

    /// 落ちたテストの数（3 件）が、一覧に出ている失敗（起動の失敗 1 件）より多い
    static let undercountedLaunchFailure = Fixtures.launchFailureSummary
        .replacingOccurrences(of: #""failedTests": 1"#, with: #""failedTests": 3"#)

    /// 起動の失敗のほかにも失敗があるとき・ほかの失敗が無いと確かめられないときは、流し直さない（epic の変更で落ちたテストを隠さない）
    @Test(arguments: [
        // Unit テストが 1 件落ち、UI テストの実行役は起動できなかった
        (Fixtures.launchFailureBuild, Fixtures.launchFailureWithFailedTest),
        (Fixtures.launchFailureBuild, undercountedLaunchFailure),
        // ビルドの結果は読めたが、テストの要約を読めない（ほかに落ちたテストがあったか分からない）
        (Fixtures.launchFailureBuild, nil),
        // 結果のバンドルを読めない（出力にだけ起動の失敗がある）
        (nil, nil)
    ] as [(String?, String?)])
    func doesNotMarkOtherFailuresAsLaunchFailures(build: String?, tests: String?) async throws {
        let (runner, _) = makeRunner(build: build, tests: tests) { _ in
            .failure(65, "Failed to install or launch the test runner.\n** TEST FAILED **\n")
        }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let outcome = try await runner.run(try request(.testLight), timeout: .seconds(600))
        #expect(outcome.failure == .environment)
        #expect(!outcome.launchFailed)
    }

    /// ビルドだけのときは、テストの実行役を起動しないので流し直さない
    @Test func doesNotMarkBuildsAsLaunchFailures() async throws {
        let (runner, _) = makeRunner(build: Fixtures.launchFailureBuild) { _ in .failure(65, "** BUILD FAILED **\n") }
        defer { try? FileManager.default.removeItem(at: runner.directories.root) }
        let outcome = try await runner.run(try request(.build), timeout: .seconds(600))
        #expect(outcome.failure == .environment)
        #expect(!outcome.launchFailed)
    }

    // MARK: - 置き場所

    @Test func removesFinishedEpicsOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-build-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = BuildDirectories(root: root)
        let active = Self.epic
        let finished = try #require(ULID(rawValue: "01JC0000000000000000000001"))
        let notes = root.appendingPathComponent("notes")
        for directory in [directories.derivedData(for: active), directories.derivedData(for: finished), notes] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #expect(try directories.removeEpics(except: [active]) == [finished])
        #expect(FileManager.default.fileExists(atPath: directories.derivedData(for: active).path))
        #expect(!FileManager.default.fileExists(atPath: directories.epicDirectory(finished).path))
        // epic の形でない名前のものには触れない
        #expect(FileManager.default.fileExists(atPath: notes.path))
        // 名前に `/` を含めても、結果のバンドルは epic の results の中に置く
        let bundle = directories.resultBundle(for: active, named: "../x y")
        #expect(bundle.deletingLastPathComponent().path == directories.epicDirectory(active).appendingPathComponent("results").path)
    }
}

/// 起動できない・取り消された runner
struct FailingRunner: CommandRunning {
    var error: any Error & Sendable

    func run(_ command: Command) async throws -> CommandResult {
        throw error
    }
}
