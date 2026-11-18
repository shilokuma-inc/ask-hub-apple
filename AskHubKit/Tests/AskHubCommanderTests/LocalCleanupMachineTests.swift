import AskHubBuild
@testable import AskHubCommander
import AskHubCommands
import AskHubProtocol
import Foundation
import os
import Testing

/// `xcrun simctl` だけを決まった応答にし、ほかのコマンド（find・git・du）は本当に流す
final class SimctlStubRunner: CommandRunning {
    private let deleted = OSAllocatedUnfairLock<[String]>(initialState: [])
    let devicesJSON: String

    init(devicesJSON: String) {
        self.devicesJSON = devicesJSON
    }

    var deletedUDIDs: [String] { deleted.withLock { $0 } }

    func run(_ command: Command) async throws -> CommandResult {
        guard command.executable.lastPathComponent == "xcrun" else { return try await ProcessCommandRunner().run(command) }
        if command.arguments.starts(with: ["simctl", "list"]) {
            return CommandResult(status: 0, standardOutput: Data(devicesJSON.utf8), standardError: Data())
        }
        if command.arguments.starts(with: ["simctl", "delete"]), let udid = command.arguments.last {
            deleted.withLock { $0.append(udid) }
            return CommandResult(status: 0, standardOutput: Data(), standardError: Data())
        }
        return CommandResult(status: 1, standardOutput: Data(), standardError: Data("unknown".utf8))
    }
}

/// 一時フォルダをホームにして、本物の git の clone と DerivedData を置いて探し、選んだものを消す（ゴミ箱は一時フォルダに差し替える）
struct LocalCleanupMachineTests {
    static let derivedDataPath = "Library/Developer/Xcode/DerivedData/OldApp-abcdefghijklmnopqrstuvwxyzab"
    static let worker = "21111111-1111-1111-1111-111111111111"
    static let booted = "31111111-1111-1111-1111-111111111111"
    static let human = "41111111-1111-1111-1111-111111111111"
    static let devices = """
        {"devices":{"com.apple.CoreSimulator.SimRuntime.iOS-26-5":[
          {"udid":"\(worker)","name":"askhub-worker-0-iPhone-17-Pro-iOS-26.5","state":"Shutdown","dataPathSize":100},
          {"udid":"\(booted)","name":"AskHub Siri 確かめ","state":"Booted","dataPathSize":200,"lastUsedAt":"2026-11-18T10:25:52Z"},
          {"udid":"\(human)","name":"iPhone 16 Pro","state":"Shutdown","dataPathSize":300}
        ]}}
        """

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("cleanup-\(UUID().uuidString)", isDirectory: true)
    var home: URL { root.appendingPathComponent("home", isDirectory: true) }
    var trash: URL { root.appendingPathComponent("trash", isDirectory: true) }

    func machine(_ runner: SimctlStubRunner) -> LocalCleanupMachine {
        let tools = BuildTools(home: home, temporaryDirectory: root)
        let trash = trash
        return LocalCleanupMachine(home: home, tools: tools, runner: runner) { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
    }

    @discardableResult
    func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        let identity = ["-c", "user.name=t", "-c", "user.email=t@example.com", "-c", "init.defaultBranch=main"]
        process.arguments = ["-C", directory.path] + identity + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// `path` に、push 済みの clone を作る
    func clone(_ path: String, remote: URL) throws -> URL {
        let directory = home.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["clone", "-q", remote.path, directory.path], in: root)
        return directory
    }

    /// 置いたもの
    struct Prepared {
        var clean: URL
        var dirty: URL
        var derivedData: URL
    }

    func prepare() throws -> Prepared {
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let seed = root.appendingPathComponent("seed", isDirectory: true)
        try FileManager.default.createDirectory(at: seed, withIntermediateDirectories: true)
        try git(["init", "-q"], in: seed)
        try "hello".write(to: seed.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: seed)
        try git(["commit", "-q", "-m", "first"], in: seed)
        let remote = root.appendingPathComponent("remote.git", isDirectory: true)
        try git(["clone", "-q", "--bare", seed.path, remote.path], in: root)

        let clean = try clone("Desktop/ios/clean-app", remote: remote)
        let dirty = try clone("Desktop/ios/dirty-app", remote: remote)
        try "change".write(to: dirty.appendingPathComponent("README"), atomically: true, encoding: .utf8)
        let worktree = try clone("Projects/with-worktree", remote: remote)
        // linked worktree（`.git` がファイル）は候補に出さず、元の clone に注意を付ける
        try git(["worktree", "add", "-q", "-b", "side", home.appendingPathComponent("Projects/with-worktree-side").path], in: worktree)
        let local = home.appendingPathComponent("Projects/local-only", isDirectory: true)
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        try git(["init", "-q"], in: local)
        // 依存のフォルダと ~/Library の中の clone は探さない
        _ = try clone("Projects/web/node_modules/pkg", remote: remote)
        _ = try clone("Library/Developer/AskHub/worker/work/repos/o/r", remote: remote)
        let derivedData = home.appendingPathComponent(Self.derivedDataPath, isDirectory: true)
        try FileManager.default.createDirectory(at: derivedData, withIntermediateDirectories: true)
        try Data(count: 4_096).write(to: derivedData.appendingPathComponent("build.db"))
        return Prepared(clean: clean, dirty: dirty, derivedData: derivedData)
    }

    @Test func findsHumanClonesSimulatorsAndDerivedDataWithCautions() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try prepare()
        let scan = await machine(SimctlStubRunner(devicesJSON: Self.devices)).scan()
        let byLocation = Dictionary(uniqueKeysWithValues: scan.candidates.map { ($0.location, $0) })
        #expect(Set(byLocation.keys) == [
            "~/Desktop/ios/clean-app", "~/Desktop/ios/dirty-app", "~/Projects/with-worktree", "~/Projects/local-only",
            "~/Library/Developer/Xcode/DerivedData/OldApp-abcdefghijklmnopqrstuvwxyzab", Self.booted, Self.human
        ])
        #expect(byLocation["~/Desktop/ios/clean-app"]?.caution == nil)
        #expect(byLocation["~/Desktop/ios/clean-app"]?.kind == .clone)
        #expect(byLocation["~/Desktop/ios/clean-app"]?.name == "clean-app")
        #expect((byLocation["~/Desktop/ios/clean-app"]?.bytes ?? 0) > 0)
        #expect(byLocation["~/Desktop/ios/dirty-app"]?.caution == "未コミットの変更がある")
        #expect(byLocation["~/Projects/with-worktree"]?.caution == "worktree がある")
        #expect(byLocation["~/Projects/local-only"]?.caution == "リモートが無い")
        let derivedData = try #require(byLocation["~/Library/Developer/Xcode/DerivedData/OldApp-abcdefghijklmnopqrstuvwxyzab"])
        #expect(derivedData.kind == .derivedData)
        #expect(derivedData.name == "OldApp")
        #expect(byLocation[Self.booted]?.caution == "起動している")
        #expect(byLocation[Self.booted]?.name == "AskHub Siri 確かめ（iOS 26.5）")
        #expect(byLocation[Self.booted]?.lastUsedAt == Timestamp(rawValue: "2026-11-18T10:25:52Z"))
        #expect(byLocation[Self.human]?.bytes == 300)
        // id は種類と場所から決まる
        #expect(byLocation.values.allSatisfy { CleanupCandidatesFile.Candidate.isID($0.id) })
        #expect(scan.unreadable.isEmpty)
    }

    @Test func removesOnlyWhatStillQualifies() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let prepared = try prepare()
        let (clean, dirty, derivedData) = (prepared.clean, prepared.dirty, prepared.derivedData)
        let runner = SimctlStubRunner(devicesJSON: Self.devices)
        let machine = machine(runner)
        let scan = await machine.scan()
        let candidate = { (location: String) in scan.candidates.first { $0.location == location } }

        // push 済みで手を付けていない clone と DerivedData は、ゴミ箱に移す
        #expect(await machine.remove(try #require(candidate("~/Desktop/ios/clean-app"))) == nil)
        #expect(!FileManager.default.fileExists(atPath: clean.path))
        #expect(FileManager.default.fileExists(atPath: trash.appendingPathComponent("clean-app/README").path))
        #expect(await machine.remove(try #require(candidate("~/" + Self.derivedDataPath))) == nil)
        #expect(!FileManager.default.fileExists(atPath: derivedData.path))

        // 探した後に未コミットの変更ができた clone は、消すときに確かめ直して消さない
        var dirtyCandidate = try #require(candidate("~/Desktop/ios/dirty-app"))
        dirtyCandidate.caution = nil
        #expect(await machine.remove(dirtyCandidate) == "未コミットの変更があるので消さなかった")
        #expect(FileManager.default.fileExists(atPath: dirty.path))

        // ホームの外・~/Library の中を指すものは消さない
        var outside = dirtyCandidate
        outside.location = "~/../escape"
        #expect(await machine.remove(outside) == "ホームの下の clone でない")
        outside.location = "~/Library/Developer/AskHub/worker/work/repos/o/r"
        #expect(await machine.remove(outside) == "ホームの下の clone でない")

        // Simulator: 人が作って止まっているものだけを simctl delete で消す
        #expect(await machine.remove(try #require(candidate(Self.human))) == nil)
        #expect(await machine.remove(try #require(candidate(Self.booted))) == "起動しているので消さなかった")
        var workerSimulator = try #require(candidate(Self.human))
        workerSimulator.location = Self.worker
        #expect(await machine.remove(workerSimulator) == "ワーカーの枠の Simulator なので消さなかった（見回りで消す）")
        #expect(runner.deletedUDIDs == [Self.human])
    }
}
