@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

struct EpicBuilderTests {
    static let iPhone = BuildDestination.simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro", osVersion: "26.5"))

    static func settings() throws -> BuildSettings {
        try BuildSettings(
            project: "App.xcodeproj",
            scheme: "App",
            destinations: [iPhone, .macOS],
            testLight: TestSelection(onlyTesting: ["AppTests"]),
            testFull: TestSelection(testPlan: "Full")
        )
    }

    /// 偽の simctl と、`xcodebuild` に `respond` を返す道具一式
    private func makeBuilder(
        simctl: FakeSimctl = FakeSimctl(),
        respond: @escaping @Sendable (Command) -> CommandResult
    ) throws -> (EpicBuilder, FakeCommands) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-build-tests-\(UUID().uuidString)")
        let fake = FakeCommands { command in
            switch command.arguments.first {
            case "simctl", "--sdk": simctl.respond(to: command)
            case "xcodebuild", "xcresulttool": respond(command)
            default: .failure(1, "")
            }
        }
        let machine = BuildMachine(
            tools: BuildTools(temporaryDirectory: root.appendingPathComponent("tmp")),
            directories: BuildDirectories(root: root),
            runner: fake,
            timeouts: BuildTimeouts(build: .seconds(60), testLight: .seconds(120), testFull: .seconds(180))
        )
        let epic = try #require(ULID(rawValue: "01JC0000000000000000000000"))
        let builder = EpicBuilder(machine: machine, settings: try Self.settings(), epic: epic, sourceDirectory: root, slot: 3)
        return (builder, fake)
    }

    private func xcodebuilds(_ fake: FakeCommands) -> [Command] {
        fake.commands.filter { $0.arguments.first == "xcodebuild" }
    }

    @Test func choosesTheCommandFromTheKindAlone() async throws {
        let (builder, fake) = try makeBuilder { _ in .output("** TEST SUCCEEDED **") }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.succeeded)
        #expect(run.summary == "iPhone 17 Pro（iOS 26.5）: テストが通った\nmacOS: テストが通った")
        #expect(run.attemptFailure == nil)
        let commands = xcodebuilds(fake)
        #expect(commands.map { $0.arguments[1] } == ["test", "test"])
        #expect(commands.allSatisfy { $0.arguments.contains("-only-testing:AppTests") && $0.timeout == .seconds(120) })
        // Simulator は枠 3 のものを用意してから流す
        let destination = try #require(commands.first?.arguments.firstIndex(of: "-destination")).advanced(by: 1)
        #expect(commands.first?.arguments[destination].hasPrefix("id=") == true)
        #expect(fake.arguments.contains { $0.prefix(3) == ["simctl", "create", "askhub-worker-3-iPhone-17-Pro-iOS-26.5"] })

        _ = try await builder.run(.testFull)
        _ = try await builder.run(.build)
        let later = xcodebuilds(fake).dropFirst(2)
        #expect(later.map { $0.arguments[1] } == ["test", "test", "build", "build"])
        #expect(later.prefix(2).allSatisfy { $0.arguments.contains("-testPlan") && $0.timeout == .seconds(180) })
        #expect(later.suffix(2).allSatisfy { $0.timeout == .seconds(60) })
    }

    @Test func stopsAtTheFirstFailedDestination() async throws {
        let (builder, fake) = try makeBuilder { _ in
            .failure(65, "/w/App/Foo.swift:3:5: error: cannot find 'x' in scope\n** BUILD FAILED **")
        }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.build)
        #expect(run.failure == .build)
        #expect(run.results.map(\.destination) == [Self.iPhone])
        #expect(xcodebuilds(fake).count == 1)
        #expect(run.attemptFailure?.failureClass == .buildFailed)
        #expect(run.attemptFailure?.message == "iPhone 17 Pro（iOS 26.5）: ビルドが通らない")
        #expect(run.text().contains("iPhone 17 Pro（iOS 26.5） の結果:\nxcodebuild の出力の抜粋:\n"))
    }

    @Test func reportsSimulatorProblemsAsEnvironmentFailures() async throws {
        let simctl = FakeSimctl(bootResult: .failure(1, "Unable to boot device in current state: Booted"))
        let (builder, fake) = try makeBuilder(simctl: simctl) { _ in .output("") }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.failure == .environment)
        #expect(run.attemptFailure?.failureClass == .unexpected)
        #expect(run.results.first?.outcome.report.log?.contains("Unable to boot") == true)
        #expect(xcodebuilds(fake).isEmpty)
    }

    // MARK: - テストの前の起動し直し

    /// 前の回が使ったまま起動している、枠 3 の Simulator
    static let bootedSlot = FakeSimctl.Device(
        udid: SimulatorPoolTests.uuid(3),
        name: "askhub-worker-3-iPhone-17-Pro-iOS-26.5",
        runtime: FakeSimctl.iOS265,
        deviceType: FakeSimctl.iPhone17Pro,
        state: "Booted"
    )

    /// 前の回の UI テストが横向きにしたまま残さないように、テストの前は起動していた Simulator を止めてから起動し直す。ビルドだけなら起動し直さない
    @Test func restartsTheBootedSimulatorBeforeTestsButNotBuilds() async throws {
        let (builder, fake) = try makeBuilder(simctl: FakeSimctl(devices: [Self.bootedSlot])) { _ in .output("** TEST SUCCEEDED **") }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        #expect(try await builder.run(.build).succeeded)
        #expect(steps(fake) == ["simctl bootstatus", "xcodebuild build", "xcodebuild build"])

        for kind in [BuildKind.testLight, .testFull] {
            let before = steps(fake).count
            #expect(try await builder.run(kind).succeeded)
            #expect(steps(fake).dropFirst(before) == [
                "simctl shutdown", "simctl bootstatus", "simctl ui", "xcodebuild test", "xcodebuild test"
            ])
        }
        #expect(fake.arguments.filter { $0.prefix(2) == ["simctl", "shutdown"] }.allSatisfy { $0[2] == Self.bootedSlot.udid })
    }

    /// 前の回の UI テストがダークにした外観は、起動し直しても残るので、テストの前にライトに戻す。ビルドだけなら触れない
    @Test func restoresTheLightAppearanceBeforeTestsButNotBuilds() async throws {
        var dark = Self.bootedSlot
        dark.appearance = "dark"
        let simctl = FakeSimctl(devices: [dark])
        let appearance = { simctl.current.first { $0.udid == dark.udid }?.appearance }
        let (builder, fake) = try makeBuilder(simctl: simctl) { _ in .output("** TEST SUCCEEDED **") }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        #expect(try await builder.run(.build).succeeded)
        #expect(appearance() == "dark")

        let before = fake.arguments.count
        #expect(try await builder.run(.testLight).succeeded)
        let steps = fake.arguments.dropFirst(before).filter { ["simctl", "xcodebuild"].contains($0.first ?? "") && $0[1] != "list" }
        #expect(steps.prefix(4).map { $0.prefix(2).joined(separator: " ") } == [
            "simctl shutdown", "simctl bootstatus", "simctl ui", "simctl ui"
        ])
        #expect(steps.dropFirst(3).first == ["simctl", "ui", dark.udid, "appearance", "light"])
        #expect(steps.dropFirst(4).first?.prefix(2) == ["xcodebuild", "test"])
        #expect(appearance() == "light")
    }

    @Test func reportsAppearanceFailuresAsEnvironmentFailures() async throws {
        var dark = Self.bootedSlot
        dark.appearance = "dark"
        let simctl = FakeSimctl(devices: [dark], appearanceResult: .failure(1, "Failed to set appearance"))
        let (builder, fake) = try makeBuilder(simctl: simctl) { _ in .output("** TEST SUCCEEDED **") }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.failure == .environment)
        #expect(run.attemptFailure?.message
            == "iPhone 17 Pro（iOS 26.5）: askhub-worker-3-iPhone-17-Pro-iOS-26.5 の外観をライトに設定できない（終了コード 1）")
        #expect(xcodebuilds(fake).isEmpty)
    }

    @Test func reportsRestartFailuresAsEnvironmentFailures() async throws {
        let shutdown = CommandResult.failure(1, "Unable to shutdown device in current state: Booting")
        let simctl = FakeSimctl(devices: [Self.bootedSlot], shutdownResult: shutdown)
        let (builder, fake) = try makeBuilder(simctl: simctl) { _ in .output("** TEST SUCCEEDED **") }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.failure == .environment)
        #expect(run.attemptFailure?.message == "iPhone 17 Pro（iOS 26.5）: askhub-worker-3-iPhone-17-Pro-iOS-26.5 を停止できない（終了コード 1）")
        #expect(run.results.first?.outcome.report.log?.contains("Unable to shutdown") == true)
        #expect(xcodebuilds(fake).isEmpty)
    }

    // MARK: - アプリかテストの実行役を起動できなかった

    static let launchFailure = FakeXcodebuild.Run(
        result: .failure(65, "Testing failed:\n\tAskHub encountered an error\n** TEST FAILED **\n"),
        build: Fixtures.launchFailureBuild,
        tests: Fixtures.launchFailureSummary
    )
    static let passed = FakeXcodebuild.Run(result: .output("** TEST SUCCEEDED **"), build: Fixtures.noErrors, tests: Fixtures.passedSummary)
    static let testFailed = CommandResult.failure(65, "** TEST FAILED **")
    static let rerunNote = "。1 回目は Simulator でアプリかテストの実行役を起動できず、Simulator を消去して起動し直してから流し直した"

    /// `simctl` と `xcodebuild` を流した順（一覧・SDK の版・結果のバンドルの読み取りは除く）
    private func steps(_ fake: FakeCommands) -> [String] {
        fake.arguments.filter { ["simctl", "xcodebuild"].contains($0.first ?? "") && $0.prefix(2) != ["simctl", "list"] }
            .map { $0.prefix(2).joined(separator: " ") }
    }

    @Test func erasesTheSimulatorAndRerunsOnceWhenTheTestRunnerCannotLaunch() async throws {
        let xcodebuild = FakeXcodebuild([Self.launchFailure, Self.passed])
        let (builder, fake) = try makeBuilder { xcodebuild.respond(to: $0) }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.succeeded)
        #expect(run.summary == "iPhone 17 Pro（iOS 26.5）: テストが通った（全 2 件）\(Self.rerunNote)\nmacOS: テストが通った（全 2 件）")
        // 枠の Simulator を止めて消去し、起動し直してから同じ Simulator で流し直す。macOS は 1 回だけ
        #expect(steps(fake) == [
            "simctl create", "simctl bootstatus", "simctl ui", "xcodebuild test",
            "simctl shutdown", "simctl erase", "simctl bootstatus", "xcodebuild test",
            "xcodebuild test"
        ])
        let destinations = xcodebuilds(fake).prefix(2).map { command in
            command.arguments.firstIndex(of: "-destination").map { command.arguments[$0 + 1] }
        }
        #expect(Set(destinations).count == 1)
        #expect(fake.arguments.contains { $0.prefix(2) == ["simctl", "erase"] && destinations.first == "id=\($0[2])" })
    }

    @Test func handsOverWhenTheTestRunnerStillCannotLaunch() async throws {
        let xcodebuild = FakeXcodebuild([Self.launchFailure])
        let (builder, fake) = try makeBuilder { xcodebuild.respond(to: $0) }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.failure == .environment)
        #expect(run.results.map(\.destination) == [Self.iPhone])
        // 流し直すのは 1 回だけ
        #expect(xcodebuild.runCount == 2)
        #expect(fake.arguments.filter { $0.prefix(2) == ["simctl", "erase"] }.count == 1)
        #expect(run.attemptFailure?.failureClass == .unexpected)
        #expect(run.attemptFailure?.message == "iPhone 17 Pro（iOS 26.5）: Simulator か Xcode の不調でビルドとテストを流せない"
            + "。Simulator を消去して起動し直し、流し直しても、アプリかテストの実行役を起動できなかった")
        #expect(run.attemptFailure?.logExcerpt?.contains("Failed to install or launch the test runner") == true)
    }

    /// 起動できたうえで落ちたテストがあるときは、流し直すと通る 2 回目があっても流し直さない（epic の変更で落ちたテストを隠さない）
    @Test(arguments: [
        // Unit テストが 1 件落ち、UI テストの実行役は起動できなかった
        (
            FakeXcodebuild.Run(result: testFailed, build: Fixtures.launchFailureBuild, tests: Fixtures.launchFailureWithFailedTest),
            .environment
        ),
        (FakeXcodebuild.Run(result: testFailed, build: Fixtures.noErrors, tests: Fixtures.failedSummary(token: "t")), .test)
    ] as [(FakeXcodebuild.Run, BuildFailureKind)])
    func doesNotRerunWhenTestsFailed(first: FakeXcodebuild.Run, kind: BuildFailureKind) async throws {
        let xcodebuild = FakeXcodebuild([first, Self.passed])
        let (builder, fake) = try makeBuilder { xcodebuild.respond(to: $0) }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.failure == kind)
        #expect(xcodebuild.runCount == 1)
        #expect(!fake.arguments.contains { $0.prefix(2) == ["simctl", "erase"] })
        #expect(run.summary.contains("流し直") == false)
    }

    @Test func keepsTheFirstFailureWhenTheSimulatorCannotBeErased() async throws {
        let simctl = FakeSimctl(eraseResult: .failure(1, "Unable to erase contents and settings in current state: Booted"))
        let xcodebuild = FakeXcodebuild([Self.launchFailure, Self.passed])
        let (builder, _) = try makeBuilder(simctl: simctl) { xcodebuild.respond(to: $0) }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.failure == .environment)
        #expect(xcodebuild.runCount == 1)
        #expect(run.attemptFailure?.message == "iPhone 17 Pro（iOS 26.5）: Simulator か Xcode の不調でビルドとテストを流せない"
            + "。Simulator を消去して起動し直せなかった（askhub-worker-3-iPhone-17-Pro-iOS-26.5 を消去できない（終了コード 1））")
    }

    /// macOS には消去して起動し直す Simulator が無いので、流し直さない
    @Test func doesNotRerunOnMacOS() async throws {
        let xcodebuild = FakeXcodebuild([Self.passed, Self.launchFailure, Self.passed])
        let (builder, fake) = try makeBuilder { xcodebuild.respond(to: $0) }
        defer { try? FileManager.default.removeItem(at: builder.sourceDirectory) }
        let run = try await builder.run(.testLight)
        #expect(run.failure == .environment)
        #expect(run.results.map(\.destination) == [Self.iPhone, .macOS])
        #expect(xcodebuild.runCount == 2)
        #expect(!fake.arguments.contains { $0.prefix(2) == ["simctl", "erase"] })
    }

    @Test func labelsDestinations() {
        #expect(BuildDestination.macOS.label == "macOS")
        #expect(BuildDestination.simulator(SimulatorDestination(platform: .visionOS, deviceType: "Apple Vision Pro")).label
            == "Apple Vision Pro（visionOS）")
        #expect(BuildKind.allCases.map(\.rawValue) == ["build", "testLight", "testFull"])
    }
}
