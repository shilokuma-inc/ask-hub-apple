import AskHubCommands
import AskHubProtocol
import Foundation

/// ワーカーの中の枠ごとに、決まった名前の Simulator を作って使い回す（`docs/renewal/operations.md` の「容量」）。
///
/// - 名前は `askhub-worker-<枠>-<機種>-<プラットフォーム>-<版>`。同じ枠・行き先なら同じ Simulator を使い回す
/// - 操作（起動・消去・停止・削除）は、この形の名前の Simulator にだけ行う。人が作った Simulator
///   （`askhub-` で始まっていても、この形でないもの）には触れない
/// - 同じ枠を同時に 2 つのビルドで使わないのは、呼ぶ側（ワーカー）が守る
public struct SimulatorPool: Sendable {
    public static let namePrefix = "askhub-worker-"

    public var tools: BuildTools
    public var runner: any CommandRunning
    /// `simctl` の 1 回の上限（起動を待つ `bootstatus` を含む）
    public var timeout: Duration

    public init(tools: BuildTools, runner: any CommandRunning, timeout: Duration = .seconds(10 * 60)) {
        self.tools = tools
        self.runner = runner
        self.timeout = timeout
    }

    /// 枠の Simulator の名前
    public static func name(slot: Int, deviceType: String, platform: SimulatorPlatform, runtimeVersion: String) -> String {
        "\(namePrefix)\(slot)-\(slug(deviceType))-\(platform.rawValue)-\(slug(runtimeVersion))"
    }

    /// ワーカーが作った Simulator の名前か（`askhub-worker-<数字>-` で始まり、英数字・`.`・`-` だけ）
    public static func isWorkerName(_ name: String) -> Bool {
        name.wholeMatch(of: #/askhub-worker-[0-9]+-[A-Za-z0-9.\-]+/#) != nil
    }

    /// 英数字と `.` のほかを `-` にし、続く `-` を 1 つにまとめる（`iPad Pro 13-inch (M5)` → `iPad-Pro-13-inch-M5`）
    static func slug(_ text: String) -> String {
        let mapped = text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == ".") ? $0 : "-" }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    // MARK: - 枠の Simulator

    /// 枠 `slot` の、`destination` 用の Simulator を用意して起動する。無ければ作り、
    /// 同じ名前でランタイムや機種が合わないもの（ランタイムを消したものなど）は消して作り直す
    public func prepare(slot: Int, for destination: SimulatorDestination) async throws(SimulatorError) -> Simulator {
        guard slot >= 0 else { throw SimulatorError("枠の番号が正しくない（\(slot)）") }
        let sdkVersion = destination.osVersion == nil ? try await sdkVersion(of: destination.platform) : nil
        let catalog = try await list()
        let (runtime, deviceType) = try catalog.resolve(destination, sdkVersion: sdkVersion)
        let name = Self.name(slot: slot, deviceType: deviceType.name, platform: destination.platform, runtimeVersion: runtime.version)
        let reusable = (catalog.devices[runtime.identifier] ?? []).first { device in
            device.name == name && device.isAvailable == true && device.deviceTypeIdentifier == deviceType.identifier
        }
        for stale in catalog.allDevices where stale.name == name && stale.udid != reusable?.udid {
            try await delete(stale)
        }
        var simulator: Simulator
        if let reusable {
            simulator = Simulator(udid: reusable.udid, name: name, runtime: runtime.identifier, state: reusable.state ?? "")
        } else {
            let udid = try await create(name: name, deviceType: deviceType.identifier, runtime: runtime.identifier)
            simulator = Simulator(udid: udid, name: name, runtime: runtime.identifier, state: "Shutdown")
        }
        // 起動していなければ起動し、使えるようになるまで待つ
        try await simctl(["bootstatus", simulator.udid, "-b"], doing: "\(name) を起動")
        simulator.state = "Booted"
        return simulator
    }

    /// 止めてから中身を消す（入れたアプリ・設定・Keychain）。次の epic に前の状態を持ち越さないときや、調子が悪いときに使う
    public func erase(_ simulator: Simulator) async throws(SimulatorError) {
        try Self.checkOwned(simulator)
        try await shutdown(simulator)
        try await simctl(["erase", simulator.udid], doing: "\(simulator.name) を消去")
    }

    /// 止める。止まっていれば何もしない
    public func shutdown(_ simulator: Simulator) async throws(SimulatorError) {
        try Self.checkOwned(simulator)
        let result = try await run(["shutdown", simulator.udid], doing: "\(simulator.name) を停止")
        // 止まっているものを止めようとすると失敗する（`Unable to shutdown device in current state: Shutdown`）
        guard result.succeeded || result.outputText.contains("current state: Shutdown") else {
            throw Self.failure("\(simulator.name) を停止", result)
        }
    }

    /// 止めてから消す
    public func delete(_ simulator: Simulator) async throws(SimulatorError) {
        try Self.checkOwned(simulator)
        try await shutdown(simulator)
        try await simctl(["delete", simulator.udid], doing: "\(simulator.name) を削除")
    }

    /// ワーカーが作った Simulator の一覧
    public func workerSimulators() async throws(SimulatorError) -> [Simulator] {
        try await list().allDevices.filter { Self.isWorkerName($0.name) }
    }

    /// 枠に属さないワーカーの Simulator（`keeping` に名前が無いもの）を消す。人が作った Simulator には触れない。
    /// 1 台を消せなくても残りは続け、消せなかったものは `failures` に入れる
    public func removeStray(keeping: Set<String>) async throws(SimulatorError) -> StraySimulators {
        var sweep = StraySimulators()
        for simulator in try await workerSimulators() where !keeping.contains(simulator.name) {
            do {
                try await delete(simulator)
                sweep.removed.append(simulator)
            } catch {
                sweep.failures.append(error)
            }
        }
        return sweep
    }

    // MARK: - simctl

    private static func checkOwned(_ simulator: Simulator) throws(SimulatorError) {
        guard isWorkerName(simulator.name) else {
            throw SimulatorError("\(simulator.name) はワーカーが作った Simulator ではないので触れない")
        }
    }

    func list() async throws(SimulatorError) -> SimulatorCatalog {
        let result = try await simctl(["list", "-j"], doing: "Simulator の一覧を取得")
        do {
            return try JSONDecoder().decode(SimulatorCatalog.self, from: result.standardOutput)
        } catch {
            throw SimulatorError("Simulator の一覧を読めない（\(error.localizedDescription)）")
        }
    }

    private func sdkVersion(of platform: SimulatorPlatform) async throws(SimulatorError) -> String {
        let command = tools.command(["--sdk", platform.sdk, "--show-sdk-version"], in: tools.temporaryDirectory, timeout: timeout)
        let result = try await run(command, doing: "\(platform.rawValue) の SDK の版を取得")
        let version = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded, version.wholeMatch(of: #/[0-9]+(\.[0-9]+)*/#) != nil else {
            throw Self.failure("\(platform.rawValue) の SDK の版を取得（この Xcode に SDK が無い）", result)
        }
        return version
    }

    private func create(name: String, deviceType: String, runtime: String) async throws(SimulatorError) -> String {
        let result = try await simctl(["create", name, deviceType, runtime], doing: "\(name) を作成")
        let udid = result.outputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: udid) != nil else {
            throw Self.failure("\(name) を作成（UDID を読めない）", result)
        }
        return udid
    }

    /// `xcrun simctl <arguments>` を流し、失敗したら投げる
    @discardableResult
    private func simctl(_ arguments: [String], doing action: String) async throws(SimulatorError) -> CommandResult {
        let result = try await run(arguments, doing: action)
        guard result.succeeded else { throw Self.failure(action, result) }
        return result
    }

    private func run(_ arguments: [String], doing action: String) async throws(SimulatorError) -> CommandResult {
        try await run(tools.command(["simctl"] + arguments, in: tools.temporaryDirectory, timeout: timeout), doing: action)
    }

    private func run(_ command: Command, doing action: String) async throws(SimulatorError) -> CommandResult {
        do {
            return try await runner.run(command)
        } catch is CancellationError {
            throw SimulatorError("取り消したので\(action)できない")
        } catch {
            throw SimulatorError("\(action)できない（xcrun を起動できない: \(error.localizedDescription)）")
        }
    }

    private static func failure(_ action: String, _ result: CommandResult) -> SimulatorError {
        let log = Redaction.excerpt(of: result.outputText, secrets: [])
        if result.timedOut { return SimulatorError("\(action)できない（時間内に終わらない）", log: log) }
        return SimulatorError("\(action)できない（終了コード \(result.status)）", log: log)
    }
}

/// `removeStray(keeping:)` の結果
public struct StraySimulators: Equatable, Sendable {
    public var removed: [Simulator] = []
    public var failures: [SimulatorError] = []

    public init(removed: [Simulator] = [], failures: [SimulatorError] = []) {
        self.removed = removed
        self.failures = failures
    }
}
