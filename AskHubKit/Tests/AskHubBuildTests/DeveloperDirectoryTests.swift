@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

/// ワーカーが使う Xcode を決めたとき（`BuildTools.developerDirectory`）の動き
struct DeveloperDirectoryTests {
    static let epic = ULID(rawValue: "01JC0000000000000000000000")!

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("askhub-developer-dir-\(UUID().uuidString)", isDirectory: true)
    }

    private func request(_ kind: BuildKind, in source: URL) throws -> BuildRequest {
        let settings = try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS])
        return BuildRequest(settings: settings, kind: kind, destination: .macOS, sourceDirectory: source, epic: Self.epic)
    }

    @Test func resolvesTheDeveloperDirectoryOfAnXcodeApp() {
        let developer = "/Applications/Xcode-27.1.0.app/Contents/Developer"
        #expect(BuildTools.developerDirectory(forXcode: "/Applications/Xcode-27.1.0.app").path == developer)
        #expect(BuildTools.developerDirectory(forXcode: "/Applications/Xcode-27.1.0.app/").path == developer)
        #expect(BuildTools.developerDirectory(forXcode: developer).path == developer)
        #expect(BuildTools.developerDirectory(forXcode: developer + "/").path == developer)
    }

    @Test func readsTheVersionFromXcodebuild() {
        #expect(BuildTools.xcodeVersion(fromVersionOutput: "Xcode 27.1\nBuild version 27A9275\n") == "27.1")
        #expect(BuildTools.xcodeVersion(fromVersionOutput: "Xcode 26.6\r\nBuild version 17F113") == "26.6")
        #expect(BuildTools.xcodeVersion(fromVersionOutput: "xcode-select: error: tool 'xcodebuild' requires Xcode") == nil)
        #expect(BuildTools.xcodeVersion(fromVersionOutput: "") == nil)
    }

    /// 本物の `/usr/bin/xcrun` で流しても、xcode-select で選んだ Xcode ではなく、決めた Xcode の `xcodebuild` が動く。
    /// 人が xcode-select を切り替えても、ワーカーのビルドとテストは決めた Xcode で流れる
    @Test func runsTheConfiguredXcodeEvenWhenXcodeSelectPointsElsewhere() async throws {
        let xcode = try FakeXcode(version: "99.1")
        let root = temporary()
        defer {
            xcode.remove()
            try? FileManager.default.removeItem(at: root)
        }
        let temporary = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let tools = BuildTools(developerDirectory: xcode.developerDirectory, temporaryDirectory: temporary)
        #expect(tools.developerDirectoryProblem == nil)
        #expect(await tools.xcodeVersion(runner: ProcessCommandRunner()) == "99.1")
        // 決めていなければ xcode-select で選んだもの（偽の Xcode ではない）
        let selected = BuildTools(temporaryDirectory: temporary)
        #expect(await selected.xcodeVersion(runner: ProcessCommandRunner()) != "99.1")

        let runner = XcodeBuildRunner(tools: tools, directories: BuildDirectories(root: root), runner: ProcessCommandRunner())
        for kind in [BuildKind.build, .testLight] {
            _ = try await runner.run(request(kind, in: root), timeout: .seconds(60))
        }
        let calls = xcode.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls.first?.hasPrefix("build -project App.xcodeproj -scheme App -destination platform=macOS") == true)
        #expect(calls.last?.hasPrefix("test -project App.xcodeproj -scheme App -destination platform=macOS") == true)
    }

    /// 決めた Xcode が無ければ、`xcodebuild` も `simctl` も流さず、理由の分かる文で止める
    @Test func refusesToRunWithoutTheConfiguredXcode() async throws {
        let root = temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("Xcode-27.1.0.app/Contents/Developer", isDirectory: true)
        let tools = BuildTools(developerDirectory: missing, temporaryDirectory: root)
        let problem = try #require(tools.developerDirectoryProblem)
        #expect(problem.hasPrefix("ワーカーが使う Xcode として設定した \(missing.path) に xcodebuild が無い"))
        #expect(problem.contains("askhub-commander xcode <Xcode.app のパス>"))
        #expect(BuildTools(temporaryDirectory: root).developerDirectoryProblem == nil)

        let fake = FakeCommands { _ in .output("** BUILD SUCCEEDED **") }
        let outcome = try await XcodeBuildRunner(tools: tools, directories: BuildDirectories(root: root), runner: fake)
            .run(request(.build, in: root), timeout: .seconds(60))
        #expect(outcome.failure == .environment)
        #expect(outcome.summary == problem)
        await #expect(throws: SimulatorError("iOS の SDK の版を取得できない。\(problem)")) {
            try await SimulatorPool(tools: tools, runner: fake).prepare(
                slot: 0, for: SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro")
            )
        }
        #expect(await tools.xcodeVersion(runner: fake) == nil)
        #expect(fake.commands.isEmpty)
    }
}
