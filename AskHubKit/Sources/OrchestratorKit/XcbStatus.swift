import Foundation

/// `xcb status --json` の出力。イベントログに無い値（load・空きメモリ・コア数・枠）を取るのに使う。
///
/// 形が変わっても読めるよう、キーは `name`・`state` 以外を任意にし、読めない Mac・ジョブは読み飛ばす。
/// `reason`（xcb の理由の文）と `jobs` の `path` はローカルパスを含むので、GitHub にそのまま書かない
public struct XcbStatus: Sendable, Equatable, Decodable {
    public struct Host: Sendable, Equatable, Decodable {
        public var name: String
        /// `ok` / `down` / `drained` / `standby`
        public var state: String
        public var cores: Int?
        public var load: Double?
        public var memoryFreePercent: Int?
        public var running: Int?
        public var slots: Int?

        public init(
            name: String,
            state: String,
            cores: Int? = nil,
            load: Double? = nil,
            memoryFreePercent: Int? = nil,
            running: Int? = nil,
            slots: Int? = nil
        ) {
            self.name = name
            self.state = state
            self.cores = cores
            self.load = load
            self.memoryFreePercent = memoryFreePercent
            self.running = running
            self.slots = slots
        }
    }

    /// xcb が調べた時刻
    public var updatedAt: Date?
    public var hosts: [Host]

    public init(updatedAt: Date? = nil, hosts: [Host]) {
        self.updatedAt = updatedAt
        self.hosts = hosts
    }

    private enum CodingKeys: String, CodingKey {
        case updatedAt, hosts
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let updatedAt = (try? container.decodeIfPresent(String.self, forKey: .updatedAt))
            .flatMap { $0 }
            .flatMap { try? Date($0, strategy: .iso8601) }
        let hosts = try container.decodeIfPresent([Lossy<Host>].self, forKey: .hosts) ?? []
        self.init(updatedAt: updatedAt, hosts: hosts.compactMap(\.value))
    }

    /// 1 つの Mac が読めなくても、ほかの Mac は読む
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?

        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    /// 出力を読む。JSON でなければ `nil`
    public static func decode(_ data: Data) -> Self? {
        try? JSONDecoder().decode(Self.self, from: data)
    }
}

/// `xcb status --json` を呼ぶ。テストでは差し替える
public protocol XcbStatusFetching: Sendable {
    func status(xcbPath: String) async throws -> XcbStatus
}

/// `xcb status --json` が失敗した理由
public enum XcbStatusError: Error, Equatable, CustomStringConvertible {
    /// 起動できない（パスの誤り・実行権限が無い）
    case launchFailed(reason: String)
    /// 時間内に終わらなかった
    case timedOut
    /// 0 以外の終了コード
    case failed(status: Int32)
    /// 出力が JSON として読めない
    case unreadableOutput

    public var description: String {
        switch self {
        case let .launchFailed(reason): "xcb を起動できません（\(reason)）"
        case .timedOut: "xcb status --json が時間内に終わりませんでした"
        case let .failed(status): "xcb status --json が終了コード \(status) で終わりました"
        case .unreadableOutput: "xcb status --json の出力を読めません"
        }
    }
}

/// xcb を子プロセスで起動して `status --json` の出力を読む
public struct XcbStatusCommand: XcbStatusFetching {
    /// 各 Mac に ssh で問い合わせるので数秒〜十数秒かかる。これを過ぎたら止める
    public static let defaultTimeout: Duration = .seconds(60)

    private let timeout: Duration

    public init(timeout: Duration = defaultTimeout) {
        self.timeout = timeout
    }

    public func status(xcbPath: String) async throws -> XcbStatus {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: xcbPath)
        process.arguments = ["status", "--json"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let (exited, exit) = AsyncStream<Int32>.makeStream()
        process.terminationHandler = { process in
            exit.yield(process.terminationStatus)
            exit.finish()
        }
        do {
            try process.run()
        } catch {
            throw XcbStatusError.launchFailed(reason: error.localizedDescription)
        }
        // パイプが一杯になって xcb が止まらないよう、終了を待つ前から読み切る
        let reader = output.fileHandleForReading
        let reading = Task.detached { (try? reader.readToEnd()) ?? Data() }
        let pid = process.processIdentifier
        let timeout = timeout
        let timer = Task {
            try await Task.sleep(for: timeout)
            kill(pid, SIGKILL)
            return true
        }
        var status: Int32 = -1
        for await value in exited {
            status = value
        }
        timer.cancel()
        let data = await reading.value
        if (try? await timer.value) == true {
            throw XcbStatusError.timedOut
        }
        guard status == 0 else {
            throw XcbStatusError.failed(status: status)
        }
        guard let decoded = XcbStatus.decode(data) else {
            throw XcbStatusError.unreadableOutput
        }
        return decoded
    }
}
