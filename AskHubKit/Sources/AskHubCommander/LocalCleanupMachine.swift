import AskHubBuild
import AskHubCommands
import AskHubProtocol
import CryptoKit
import Foundation

/// この Mac の片付けの候補を探し、人が選んだものを消す（`docs/renewal/operations.md` の「容量」）。
///
/// - clone: ホームの下（デスクトップ・書類なども。`~/Library`・ゴミ箱・依存のフォルダは除く）の git の clone。worktree（`.git` がファイルのもの）は除く。
///   ホームの直下のフォルダごとに `find` を流し、読めない（macOS の許可が無い）・時間内に終わらないフォルダは「読めなかった場所」にする
/// - Simulator: ワーカーが作ったもの（`SimulatorPool.isWorkerName`）を除くすべて
/// - DerivedData: `~/Library/Developer/Xcode/DerivedData` の直下のフォルダ（ワーカーの DerivedData は別の場所にある）
///
/// clone は、未コミットの変更・未 push のコミット・stash・worktree・リモートが無いものに注意を付け、注意のあるものは消さない。
/// clone と DerivedData はゴミ箱に移す（取り消せる。空き容量はゴミ箱を空にしたときに増える）。Simulator はゴミ箱に移せないので `simctl delete` で消す
public struct LocalCleanupMachine: CleanupMachine {
    public var home: URL
    public var tools: BuildTools
    public var runner: any CommandRunning
    /// 1 つのフォルダを探す・1 つの clone を調べるコマンドの上限
    public var timeout: Duration
    /// ゴミ箱に移す（テストでは差し替える）
    public var moveToTrash: @Sendable (URL) throws -> Void

    public init(
        home: URL,
        tools: BuildTools,
        runner: any CommandRunning,
        timeout: Duration = .seconds(5 * 60),
        moveToTrash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.home = home.standardizedFileURL
        self.tools = tools
        self.runner = runner
        self.timeout = timeout
        self.moveToTrash = moveToTrash
    }

    /// 探すときに降りないフォルダ（中に clone を置かない・大きいもの）
    static let prunedNames = ["node_modules", ".build", "DerivedData", "Pods", "SourcePackages", ".swiftpm", "Carthage"]
    /// ホームの直下から何階層まで探すか
    static let searchDepth = 6

    var derivedDataRoot: URL { home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true) }

    // MARK: - 探す

    public func scan() async -> CleanupScan {
        var scan = CleanupScan(candidates: [])
        let (clones, unreadable) = await cloneDirectories()
        scan.unreadable = unreadable
        for clone in clones {
            scan.candidates.append(await cloneCandidate(clone))
        }
        let derivedData = await derivedDataCandidates()
        scan.candidates += derivedData.candidates
        if derivedData.unreadable { scan.unreadable.append(display(derivedDataRoot)) }
        switch await humanSimulators() {
        case let .success(simulators):
            scan.candidates += simulators
        case let .failure(problem):
            scan.unreadable.append("Simulator（\(problem)）")
        }
        return scan
    }

    /// ホームの直下のフォルダごとに `.git` を探す。clone のフォルダと、読めなかった場所を返す
    func cloneDirectories() async -> (clones: [URL], unreadable: [String]) {
        let roots: [URL]
        do {
            roots = try FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: [.isDirectoryKey])
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                        && !url.lastPathComponent.hasPrefix(".") && url.lastPathComponent != "Library"
                }
                .sorted { $0.path < $1.path }
        } catch {
            return ([], ["~"])
        }
        var clones: [URL] = []
        var unreadable: [String] = []
        for root in roots {
            let pruned = Self.prunedNames.flatMap { ["-o", "-name", $0] }
            let arguments = [root.path, "-maxdepth", "\(Self.searchDepth)", "("] + ["-name", ".Trash"] + pruned
                + [")", "-prune", "-o", "-name", ".git", "-type", "d", "-print0", "-prune"]
            let command = Command(
                executable: URL(fileURLWithPath: "/usr/bin/find"), arguments: arguments, workingDirectory: home, timeout: timeout
            )
            guard let result = try? await runner.run(command) else {
                unreadable.append(display(root))
                continue
            }
            // パスに改行を含むフォルダもあり得るので、NUL で区切る
            let found = result.standardOutput.split(separator: 0).compactMap { bytes in
                String(bytes: bytes, encoding: .utf8).map { URL(fileURLWithPath: $0).deletingLastPathComponent().standardizedFileURL }
            }
            clones += found
            if result.timedOut {
                unreadable.append("\(display(root))（時間内に探し終えなかった）")
            } else if !result.succeeded {
                // 読めない下のフォルダ（`find: …: Operation not permitted`）があった。macOS の許可が無いと、フォルダごと読めない
                unreadable.append(display(root))
            }
        }
        return (clones, unreadable)
    }

    /// clone の候補。注意（消さない理由）を調べる
    func cloneCandidate(_ directory: URL) async -> CleanupCandidatesFile.Candidate {
        let location = display(directory)
        return CleanupCandidatesFile.Candidate(
            id: Self.id(kind: .clone, location: location),
            kind: .clone,
            name: directory.lastPathComponent,
            location: location,
            bytes: await size(of: directory),
            lastUsedAt: lastModified(directory.appendingPathComponent(".git/index"))
                ?? lastModified(directory.appendingPathComponent(".git")),
            caution: await cloneCaution(directory)
        )
    }

    /// clone を消してはいけない理由（未コミット・未 push・stash・worktree・リモートが無い）。無ければ nil
    func cloneCaution(_ directory: URL) async -> String? {
        var reasons: [String] = []
        // 未追跡のファイルは、人の設定（`status.showUntrackedFiles=no`）によらず出させる。
        // 未 push は、ブランチに加えて detached の HEAD も見る（HEAD がまだコミットを指さなければ見ない）。出力はコミットの id だけにする
        let hasHead = await git(["rev-parse", "--verify", "--quiet", "HEAD"], in: directory) != nil
        let unpushedArguments = ["rev-list", "--max-count=1", "--branches"] + (hasHead ? ["HEAD"] : []) + ["--not", "--remotes"]
        guard let status = await git(["status", "--porcelain", "--untracked-files=normal"], in: directory),
              let remotes = await git(["remote"], in: directory),
              let unpushed = await git(unpushedArguments, in: directory),
              let stash = await git(["stash", "list", "--format=%H"], in: directory),
              let worktrees = await git(["worktree", "list", "--porcelain"], in: directory) else {
            return "git の状態を読めない"
        }
        if !status.isEmpty { reasons.append("未コミットの変更がある") }
        if remotes.isEmpty {
            reasons.append("リモートが無い")
        } else if !unpushed.isEmpty {
            reasons.append("未 push のコミットがある")
        }
        if !stash.isEmpty { reasons.append("stash がある") }
        if worktrees.components(separatedBy: "\n").filter({ $0.hasPrefix("worktree ") }).count > 1 { reasons.append("worktree がある") }
        // 親の .gitignore に入る別の clone・worktree は、親の git status に出ないので、中を探して確かめる（一緒にゴミ箱に移さない）
        switch await containsNestedRepository(directory) {
        case true?: reasons.append("中に別の clone か worktree がある")
        case nil: reasons.append("中の別の clone を確かめられない")
        case false?: break
        }
        return reasons.isEmpty ? nil : reasons.joined(separator: "・")
    }

    /// clone の中（自分の `.git` のほか）に、別の clone か worktree（`.git` のフォルダかファイル）があるか。確かめられなければ nil
    func containsNestedRepository(_ directory: URL) async -> Bool? {
        let own = directory.appendingPathComponent(".git").path
        let arguments = [directory.path, "-path", own, "-prune", "-o", "-name", ".git", "-print", "-quit"]
        let command = Command(
            executable: URL(fileURLWithPath: "/usr/bin/find"), arguments: arguments, workingDirectory: home, timeout: timeout
        )
        guard let result = try? await runner.run(command), result.succeeded else { return nil }
        return !result.standardOutput.isEmpty
    }

    /// Xcode の DerivedData の直下のフォルダ
    /// フォルダが無ければ候補も無い。読めなければ（許可が無いなど）`unreadable`
    func derivedDataCandidates() async -> (candidates: [CleanupCandidatesFile.Candidate], unreadable: Bool) {
        let folders: [URL]
        do {
            folders = try FileManager.default.contentsOfDirectory(at: derivedDataRoot, includingPropertiesForKeys: [.isDirectoryKey])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ([], false)
        } catch {
            return ([], true)
        }
        var candidates: [CleanupCandidatesFile.Candidate] = []
        for folder in folders.sorted(by: { $0.path < $1.path })
        where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let location = display(folder)
            // `<プロジェクト>-<28 文字のハッシュ>` の形なら、プロジェクトの名前だけにする
            let name = folder.lastPathComponent.replacing(#/-[a-z]{28}$/#, with: "")
            candidates.append(.init(
                id: Self.id(kind: .derivedData, location: location),
                kind: .derivedData,
                name: name,
                location: location,
                bytes: await size(of: folder),
                lastUsedAt: lastModified(folder)
            ))
        }
        return (candidates, false)
    }

    /// ワーカーが作っていない Simulator
    func humanSimulators() async -> Result<[CleanupCandidatesFile.Candidate], CleanupProblem> {
        let devices: [SimulatorDevice]
        switch await simulatorDevices() {
        case let .success(list): devices = list
        case let .failure(problem): return .failure(problem)
        }
        return .success(devices.filter { !SimulatorPool.isWorkerName($0.name) }.map { device in
            CleanupCandidatesFile.Candidate(
                id: Self.id(kind: .simulator, location: device.udid),
                kind: .simulator,
                name: "\(device.name)（\(device.runtimeName)）",
                location: device.udid,
                bytes: device.dataPathSize ?? 0,
                lastUsedAt: device.lastUsedAt.flatMap(Timestamp.init(rawValue:)),
                caution: device.state == "Booted" ? "起動している" : nil
            )
        })
    }

    // MARK: - 消す

    public func remove(_ candidate: CleanupCandidatesFile.Candidate) async -> String? {
        switch candidate.kind {
        case .clone:
            guard let directory = path(of: candidate.location), directory.path.hasPrefix(home.path + "/"),
                  !directory.path.hasPrefix(home.appendingPathComponent("Library").path + "/") else {
                return "ホームの下の clone でない"
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return "git の clone でなくなった"
            }
            if let caution = await cloneCaution(directory) { return "\(caution)ので消さなかった" }
            return trash(directory)
        case .derivedData:
            guard let folder = path(of: candidate.location),
                  folder.deletingLastPathComponent().standardizedFileURL == derivedDataRoot.standardizedFileURL else {
                return "Xcode の DerivedData のフォルダでない"
            }
            return trash(folder)
        case .simulator:
            return await deleteSimulator(candidate)
        }
    }

    /// 人が作った Simulator を消す。まだあり、ワーカーのものでなく、起動していないときだけ。Simulator はゴミ箱に移せない
    func deleteSimulator(_ candidate: CleanupCandidatesFile.Candidate) async -> String? {
        let devices: [SimulatorDevice]
        switch await simulatorDevices() {
        case let .success(list): devices = list
        case let .failure(problem): return "Simulator の一覧を読めない（\(problem.message)）"
        }
        guard let device = devices.first(where: { $0.udid == candidate.location }) else { return "Simulator が見つからない（もう消した）" }
        guard !SimulatorPool.isWorkerName(device.name) else { return "ワーカーの枠の Simulator なので消さなかった（見回りで消す）" }
        guard device.state != "Booted" else { return "起動しているので消さなかった" }
        let command = tools.command(["simctl", "delete", device.udid], in: tools.temporaryDirectory, timeout: timeout)
        guard let result = try? await runner.run(command), result.succeeded else { return "simctl delete に失敗した" }
        return nil
    }

    /// ゴミ箱に移す。移せなければ理由（取り消せない消し方はしない）
    func trash(_ url: URL) -> String? {
        do {
            try moveToTrash(url)
            return nil
        } catch {
            return "ゴミ箱に移せなかった（\(error.localizedDescription)）"
        }
    }

    // MARK: - 部品

    /// 候補の id。種類と場所から決める（探し直しても同じものは同じ id）
    static func id(kind: CleanupCandidateKind, location: String) -> String {
        CleanupCandidatesFile.Candidate.id(kind: kind, location: location)
    }

    /// ホームからのパス（`~/Desktop/ios/app`）
    func display(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return path.hasPrefix(home.path + "/") ? "~/" + path.dropFirst(home.path.count + 1) : path
    }

    /// ホームからのパスを戻す。`..` を含むもの・ホームの外を指すものは nil
    func path(of location: String) -> URL? {
        guard location.hasPrefix("~/"), !location.split(separator: "/").contains("..") else { return nil }
        let url = home.appendingPathComponent(String(location.dropFirst(2))).standardizedFileURL
        return url.path.hasPrefix(home.path + "/") ? url : nil
    }

    func size(of directory: URL) async -> Int64 {
        let command = Command(
            executable: URL(fileURLWithPath: "/usr/bin/du"), arguments: ["-sk", directory.path], workingDirectory: home, timeout: timeout
        )
        guard let result = try? await runner.run(command), let line = Self.lines(result.standardOutput).first,
              let kilobytes = line.split(whereSeparator: \.isWhitespace).first.flatMap({ Int64($0) }) else {
            return 0
        }
        return kilobytes * 1_024
    }

    func lastModified(_ url: URL) -> Timestamp? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map(Timestamp.init)
    }

    /// `git -C <directory> <arguments>` の出力（前後の空白を除く）。失敗したら nil。作業場所の状態を書き換えない（index を書かない）
    func git(_ arguments: [String], in directory: URL) async -> String? {
        let command = Command(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-C", directory.path, "-c", "core.fsmonitor=false"] + arguments,
            environment: ["GIT_OPTIONAL_LOCKS": "0", "GIT_TERMINAL_PROMPT": "0", "HOME": home.path, "PATH": "/usr/bin:/bin"],
            workingDirectory: directory,
            timeout: timeout
        )
        // UTF-8 で読めない出力は、空（変更なし）と取り違えないよう、読めなかったことにする
        guard let result = try? await runner.run(command), result.succeeded,
              let text = String(bytes: result.standardOutput, encoding: .utf8) else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 出力の行。UTF-8 で読めない出力は空にする
    static func lines(_ data: Data) -> [String] {
        String(bytes: data, encoding: .utf8)?.split(separator: "\n").map(String.init) ?? []
    }

    /// `simctl list -j devices` の Simulator
    func simulatorDevices() async -> Result<[SimulatorDevice], CleanupProblem> {
        let command = tools.command(["simctl", "list", "-j", "devices"], in: tools.temporaryDirectory, timeout: timeout)
        guard let result = try? await runner.run(command), result.succeeded else { return .failure(CleanupProblem("simctl list に失敗した")) }
        guard let list = try? JSONDecoder().decode(SimulatorDeviceList.self, from: result.standardOutput) else {
            return .failure(CleanupProblem("simctl list の出力を読めない"))
        }
        return .success(list.devices.keys.sorted().flatMap { runtime in
            (list.devices[runtime] ?? []).map { device in
                var device = device
                // `com.apple.CoreSimulator.SimRuntime.iOS-26-5` → `iOS 26.5`
                let parts = (runtime.split(separator: ".").last.map(String.init) ?? runtime).split(separator: "-")
                let platform = parts.first.map(String.init) ?? runtime
                device.runtimeName = "\(platform) \(parts.dropFirst().joined(separator: "."))"
                return device
            }
        })
    }
}

/// 探せない理由
public struct CleanupProblem: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }
}

/// `simctl list -j devices` の 1 台
struct SimulatorDevice: Decodable, Equatable {
    var udid: String
    var name: String
    var state: String?
    var lastUsedAt: String?
    var dataPathSize: Int64?
    /// ランタイムの短い名前（`iOS 26.5`）。一覧のキーから付ける
    var runtimeName = ""

    enum CodingKeys: String, CodingKey {
        case udid, name, state, lastUsedAt, dataPathSize
    }
}

private struct SimulatorDeviceList: Decodable {
    var devices: [String: [SimulatorDevice]]
}
