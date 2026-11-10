@testable import AskHubBuild
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

/// ビルドの前にプロジェクトを作る（`BuildSettings.generate`。XcodeGen のリポジトリ）
struct ProjectGenerationTests {
    static let epic = ULID(rawValue: "01JC0000000000000000000000")!
    static let source = URL(fileURLWithPath: "/Users/me/Library/Developer/AskHub/commander/work/01JC/App")

    /// 一時フォルダの下の置き場所と、道具のフォルダ（`installed` なら実行できる `xcodegen` を置く）。使い終わったら `remove()` で消す
    struct Place {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("askhub-generate-tests-\(UUID().uuidString)")
        var tools: URL { root.appendingPathComponent("bin") }

        init(installed: Bool) throws {
            try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: true)
            if installed {
                try Self.install("xcodegen", in: tools, executable: true)
            }
        }

        static func install(_ name: String, in directory: URL, executable: Bool) throws {
            let path = directory.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\nexit 0\n".utf8))
            try FileManager.default.setAttributes([.posixPermissions: executable ? 0o755 : 0o644], ofItemAtPath: path)
        }

        func buildTools() -> BuildTools {
            BuildTools(
                home: URL(fileURLWithPath: "/Users/me"), temporaryDirectory: root.appendingPathComponent("tmp"), toolDirectories: [tools]
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    static let generated = CommandResult.output("Generating project...\nCreated project at App.xcodeproj\n")

    /// `xcodegen` は `generate` の結果を返し、`xcodebuild` は通る（結果のバンドルは作らない）
    private func makeRunner(
        _ place: Place,
        generate: @escaping @Sendable (Command) -> CommandResult = { _ in generated }
    ) -> (XcodeBuildRunner, FakeCommands) {
        let fake = FakeCommands { command in
            if command.executable.lastPathComponent == "xcodegen" { return generate(command) }
            if command.arguments.first == "xcresulttool" { return .failure(1, "") }
            return .output("** BUILD SUCCEEDED **\n")
        }
        let runner = XcodeBuildRunner(tools: place.buildTools(), directories: BuildDirectories(root: place.root), runner: fake)
        return (runner, fake)
    }

    private func request(_ generate: ProjectGenerator? = .xcodegen) throws -> BuildRequest {
        let settings = try BuildSettings(project: "App.xcodeproj", generate: generate, scheme: "App", destinations: [.macOS])
        return BuildRequest(settings: settings, kind: .build, destination: .macOS, sourceDirectory: Self.source, epic: Self.epic)
    }

    @Test func generatesTheProjectInTheCheckoutBeforeXcodebuild() async throws {
        let place = try Place(installed: true)
        defer { place.remove() }
        let (runner, fake) = makeRunner(place)
        let outcome = try await runner.run(try request(), timeout: .seconds(600))
        #expect(outcome.succeeded)

        let generate = try #require(fake.commands.first)
        #expect(generate.executable == place.tools.appendingPathComponent("xcodegen"))
        #expect(generate.arguments == ["generate"])
        #expect(generate.workingDirectory == Self.source)
        // xcodebuild と同じく、作り直した環境変数で流す（トークンなどを渡さない）
        #expect(generate.environment == runner.tools.environment)
        // 生成の上限（5 分）とビルドの残りの短いほう
        #expect(generate.timeout == .seconds(5 * 60))
        #expect(fake.arguments.dropFirst().first?.prefix(2) == ["xcodebuild", "build"])

        let (short, shortFake) = makeRunner(place)
        _ = try await short.run(try request(), timeout: .seconds(60))
        #expect(shortFake.commands.first?.timeout == .seconds(60))
    }

    @Test func usesTheProjectAsItIsWithoutTheSetting() async throws {
        let place = try Place(installed: true)
        defer { place.remove() }
        let (runner, fake) = makeRunner(place)
        let outcome = try await runner.run(try request(nil), timeout: .seconds(600))
        #expect(outcome.succeeded)
        #expect(!fake.commands.contains { $0.executable.lastPathComponent == "xcodegen" })
        #expect(fake.arguments.first?.prefix(2) == ["xcodebuild", "build"])
    }

    @Test func failedGenerationIsABuildFailureForClaudeWithTheOutput() async throws {
        let place = try Place(installed: true)
        defer { place.remove() }
        let (runner, fake) = makeRunner(place) { _ in
            .failure(1, "Spec validation error:\n\tTarget \"App\" has a missing source directory \"\(Self.source.path)/App/Missing\"\n")
        }
        let outcome = try await runner.run(try request(), timeout: .seconds(600))
        #expect(outcome.failure == .build)
        #expect(outcome.summary == "プロジェクトを作れない（xcodegen generate の終了コード 1）")
        // 理由は次の行に続くので、エラーの行だけにしない。写しのパスは相対パスにする
        #expect(outcome.report.log == "Spec validation error:\n\tTarget \"App\" has a missing source directory \"App/Missing\"")
        #expect(outcome.attemptFailure?.failureClass == .buildFailed)
        #expect(fake.commands.count == 1)

        let (lines, _) = makeRunner(place) { _ in
            .failure(1, "Decoding failed at \"targets\": Expected to decode Dictionary but found an array\n")
        }
        let decoding = try await lines.run(try request(), timeout: .seconds(600))
        #expect(decoding.report.text().contains("Decoding failed at \"targets\""))
    }

    @Test func missingToolIsAnEnvironmentProblem() async throws {
        let place = try Place(installed: false)
        defer { place.remove() }
        let (runner, fake) = makeRunner(place)
        let outcome = try await runner.run(try request(), timeout: .seconds(600))
        #expect(outcome.failure == .environment)
        #expect(outcome.summary == "プロジェクトを作れない（xcodegen が見つからない（\(place.tools.path) に入れる））")
        #expect(outcome.attemptFailure?.failureClass == .unexpected)
        #expect(fake.commands.isEmpty)
    }

    @Test func slowGenerationIsATimeout() async throws {
        let place = try Place(installed: true)
        defer { place.remove() }
        let (runner, fake) = makeRunner(place) { _ in
            CommandResult(status: 15, terminatedBySignal: true, standardOutput: Data(), standardError: Data(), timedOut: true)
        }
        let outcome = try await runner.run(try request(), timeout: .seconds(600))
        #expect(outcome.failure == .timeout)
        #expect(outcome.summary == "プロジェクトを作る xcodegen generate が時間の上限を超えた")
        #expect(fake.commands.count == 1)
    }

    @Test func findsTheFirstExecutableTool() throws {
        let place = try Place(installed: false)
        defer { place.remove() }
        let first = place.root.appendingPathComponent("first")
        let second = place.root.appendingPathComponent("second")
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // 実行できないファイルは飛ばす
        try Place.install("xcodegen", in: first, executable: false)
        try Place.install("xcodegen", in: second, executable: true)
        let tools = BuildTools(temporaryDirectory: place.root, toolDirectories: [first, second])
        #expect(tools.tool(named: "xcodegen") == second.appendingPathComponent("xcodegen"))
        #expect(tools.tool(named: "tuist") == nil)
        let defaults = BuildTools(home: URL(fileURLWithPath: "/Users/me"), temporaryDirectory: place.root).toolDirectories
        #expect(defaults.map(\.path) == ["/opt/homebrew/bin", "/usr/local/bin", "/Users/me/.local/bin"])
    }
}
