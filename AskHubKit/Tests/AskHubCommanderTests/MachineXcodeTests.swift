import AskHubBuild
@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import Testing

/// 司令塔とワーカーがビルドとテストに使う Xcode を、設定（`xcode`）で決める
struct MachineXcodeTests {
    static let epic = ULID(rawValue: "01JC0000000000000000000000")!
    static let executable = URL(fileURLWithPath: "/usr/local/bin/askhub-commander")

    static func configuration(xcode: String? = nil) throws -> MachineConfiguration {
        MachineConfiguration(
            stateRepository: try #require(RepositoryFullName(rawValue: "shilokuma-inc/askhub-state")),
            mac: try #require(MacName(rawValue: "mac-mini")),
            claude: "/opt/claude/claude",
            keyAccounts: ["mrs1669"],
            capacity: .init(claude: 2, build: 1),
            xcode: xcode
        )
    }

    private func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("MachineXcodeTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// 決める前の設定（`xcode` の欄が無い）も読め、xcode-select で選んだものを使う（`DEVELOPER_DIR` を渡さない）
    @Test func readsConfigurationsWithoutXcode() throws {
        let text = #"""
            {"capacity":{"build":0,"claude":2},"claude":"/opt/claude","githubOwners":[],"keyAccounts":["a"],"kind":"alwaysOn",
             "mac":"mac-mini","stateRepository":"o/r"}
            """#
        let configuration = try JSONDecoder().decode(MachineConfiguration.self, from: Data(text.utf8))
        #expect(configuration.xcode == nil)
        #expect(configuration.developerDirectory == nil)
        let paths = MachinePaths(role: .commander, home: URL(fileURLWithPath: "/Users/me"))
        #expect(configuration.buildTools(paths: paths).environment["DEVELOPER_DIR"] == nil)
        // 決めていなければ、設定のファイルにも欄を書かない
        let encoded = try String(bytes: JSONEncoder().encode(configuration), encoding: .utf8)
        #expect(encoded?.contains("xcode") == false)

        var pinned = configuration
        pinned.xcode = "/Applications/Xcode-27.1.0.app"
        #expect(try JSONDecoder().decode(MachineConfiguration.self, from: JSONEncoder().encode(pinned)) == pinned)
        let tools = pinned.buildTools(paths: paths)
        #expect(tools.environment["DEVELOPER_DIR"] == "/Applications/Xcode-27.1.0.app/Contents/Developer")
        #expect(tools.temporaryDirectory == paths.buildTemporary)
        pinned.xcode = "Xcode.app"
        #expect(pinned.problems == ["xcode は Xcode.app の絶対パスで書く"])
    }

    @Test func parsesXcodeArguments() throws {
        #expect(try XcodeSetup.parse(["/Applications/Xcode-27.1.0.app/"]) == .set("/Applications/Xcode-27.1.0.app"))
        let developer = "/Applications/Xcode-27.1.0.app/Contents/Developer"
        #expect(try XcodeSetup.parse([developer]) == .set(developer))
        #expect(try XcodeSetup.parse(["--unset"]) == .unset)
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(try XcodeSetup.parse(["~/Applications/Xcode.app"]) == .set(home + "/Applications/Xcode.app"))
        let failures: [([String], String)] = [
            ([], "Xcode.app のパスか --unset を 1 つ渡す"),
            ([""], "Xcode.app のパスか --unset を 1 つ渡す"),
            (["/Applications/Xcode.app", "--unset"], "Xcode.app のパスか --unset を 1 つ渡す"),
            (["Xcode.app"], "Xcode.app の絶対パスを渡す（Xcode.app）")
        ]
        for (arguments, message) in failures {
            #expect(throws: MachineSetup.Failure(message: message)) { try XcodeSetup.parse(arguments) }
        }
    }

    /// setup を流し直しても、決めた Xcode は残す（忘れて xcode-select に戻らないように）
    @Test func keepsXcodeAcrossSetup() throws {
        let url = temporary().appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"mac":"m","xcode":"/Applications/Xcode-27.1.0.app"}"#.utf8).write(to: url)
        #expect(MachineConfiguration.preservedXcode(at: url) == "/Applications/Xcode-27.1.0.app")
        try Data(#"{"mac":"m"}"#.utf8).write(to: url)
        #expect(MachineConfiguration.preservedXcode(at: url) == nil)
        #expect(MachineConfiguration.preservedXcode(at: url.appendingPathExtension("missing")) == nil)
    }

    /// `xcode <パス>` で決めた Xcode を設定に書き、その設定から組み立てたビルドは、xcode-select で選んだものではなく決めた Xcode で流れる。
    /// `--unset` で xcode-select で選んだものに戻す
    @Test func buildsWithTheXcodeChosenByTheCommand() async throws {
        let xcode = try FakeXcode(version: "99.1")
        let home = temporary()
        defer {
            xcode.remove()
            try? FileManager.default.removeItem(at: home)
        }
        let commandLine = MachineCommandLine(role: .commander, executable: Self.executable, home: home)
        try Self.configuration().save(to: commandLine.paths.configuration)

        await commandLine.xcode([xcode.app.path + "/"])
        let configuration = commandLine.loadConfiguration()
        #expect(configuration.xcode == xcode.app.path)
        #expect(await commandLine.xcodeLine(configuration) == "\(xcode.app.path)（Xcode 99.1）")

        // 司令塔・ワーカーの組み立て（`MachineRuntime`）と同じく、設定から道具を作って流す
        let tools = configuration.buildTools(paths: commandLine.paths)
        #expect(tools.environment["DEVELOPER_DIR"] == xcode.developerDirectory.path)
        let source = home.appendingPathComponent("repository", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let directories = BuildDirectories(root: commandLine.paths.builds)
        let machine = BuildMachine(tools: tools, directories: directories, runner: ProcessCommandRunner())
        let settings = try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS])
        let builder = EpicBuilder(machine: machine, settings: settings, epic: Self.epic, sourceDirectory: source, slot: 0)
        _ = try await builder.run(.build)
        _ = try await builder.run(.testFull)
        let calls = xcode.recordedCalls()
        #expect(calls.count == 2)
        #expect(calls.first?.hasPrefix("build -project App.xcodeproj -scheme App -destination platform=macOS") == true)
        #expect(calls.last?.hasPrefix("test -project App.xcodeproj -scheme App -destination platform=macOS") == true)

        await commandLine.xcode(["--unset"])
        let unset = commandLine.loadConfiguration()
        #expect(unset.xcode == nil)
        #expect(unset.buildTools(paths: commandLine.paths).environment["DEVELOPER_DIR"] == nil)
        #expect(await commandLine.xcodeLine(unset).hasPrefix("設定で決めていない。xcode-select で選んだ "))
    }

    /// 決めた Xcode を消したら、ビルドの前に理由の分かる文で止める（`check` にも出す）
    @Test func stopsBeforeBuildingWhenTheChosenXcodeIsGone() async throws {
        let home = temporary()
        defer { try? FileManager.default.removeItem(at: home) }
        let missing = home.appendingPathComponent("Xcode-27.1.0.app").path
        let configuration = try Self.configuration(xcode: missing)
        let commandLine = MachineCommandLine(role: .commander, executable: Self.executable, home: home)
        #expect(await commandLine.xcodeLine(configuration) == "設定の \(missing) に Xcode が無い（ビルドとテストは止まる。xcode <Xcode.app のパス> で決め直す）")

        let tools = configuration.buildTools(paths: commandLine.paths)
        let directories = BuildDirectories(root: commandLine.paths.builds)
        let machine = BuildMachine(tools: tools, directories: directories, runner: ProcessCommandRunner())
        let settings = try BuildSettings(project: "App.xcodeproj", scheme: "App", destinations: [.macOS])
        let run = try await EpicBuilder(machine: machine, settings: settings, epic: Self.epic, sourceDirectory: home, slot: 0).run(.build)
        #expect(run.failure == .environment)
        #expect(run.summary.hasPrefix("macOS: ワーカーが使う Xcode として設定した \(missing)/Contents/Developer に xcodebuild が無い"))
    }
}
