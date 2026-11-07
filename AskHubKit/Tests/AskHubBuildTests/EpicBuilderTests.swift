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
            pullRequestTests: TestSelection(onlyTesting: ["AppTests"]),
            finalTests: TestSelection(testPlan: "Full")
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
            case "xcodebuild": respond(command)
            default: .failure(1, "")
            }
        }
        let machine = BuildMachine(
            tools: BuildTools(temporaryDirectory: root.appendingPathComponent("tmp")),
            directories: BuildDirectories(root: root),
            runner: fake,
            timeouts: BuildTimeouts(build: .seconds(60), pullRequestTests: .seconds(120), finalTests: .seconds(180))
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
        let run = try await builder.run(.pullRequestTests)
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

        _ = try await builder.run(.finalTests)
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
        let run = try await builder.run(.pullRequestTests)
        #expect(run.failure == .environment)
        #expect(run.attemptFailure?.failureClass == .unexpected)
        #expect(run.results.first?.outcome.report.log?.contains("Unable to boot") == true)
        #expect(xcodebuilds(fake).isEmpty)
    }

    @Test func labelsDestinations() {
        #expect(BuildDestination.macOS.label == "macOS")
        #expect(BuildDestination.simulator(SimulatorDestination(platform: .visionOS, deviceType: "Apple Vision Pro")).label
            == "Apple Vision Pro（visionOS）")
        #expect(BuildKind.allCases.map(\.rawValue) == ["build", "pullRequestTests", "finalTests"])
    }
}
