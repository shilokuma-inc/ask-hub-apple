import Foundation

/// 制限時間つきで流すコマンド。環境変数は親から引き継がず、`environment` に書いたものだけを渡す
/// （資格情報を子に漏らさないため。`docs/renewal/security.md` の「資格情報を渡さない」）
public struct Command: Equatable, Sendable {
    /// 実行するファイル（絶対パス）
    public var executable: URL
    public var arguments: [String]
    public var environment: [String: String]
    public var workingDirectory: URL
    /// 実行時間の上限。超えたら SIGINT、`interruptGrace` 待っても終わらなければ SIGTERM、
    /// さらに `terminateGrace` 待っても残っていれば SIGKILL を、コマンドとその子孫に送る
    public var timeout: Duration
    public var interruptGrace: Duration
    public var terminateGrace: Duration

    public init(
        executable: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        workingDirectory: URL,
        timeout: Duration,
        interruptGrace: Duration = .seconds(10),
        terminateGrace: Duration = .seconds(10)
    ) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
        self.interruptGrace = interruptGrace
        self.terminateGrace = terminateGrace
    }
}

/// コマンドの結果。標準入力は空（`/dev/null`）で流す
public struct CommandResult: Equatable, Sendable {
    /// 終了コード。シグナルで終わったときはシグナルの番号
    public var status: Int32
    /// シグナルで終わったか
    public var terminatedBySignal: Bool
    /// 標準出力と標準エラー。長すぎるときは末尾だけを残す
    public var standardOutput: Data
    public var standardError: Data
    /// 実行時間の上限を超えて止めたか
    public var timedOut: Bool

    public init(status: Int32, terminatedBySignal: Bool = false, standardOutput: Data, standardError: Data, timedOut: Bool = false) {
        self.status = status
        self.terminatedBySignal = terminatedBySignal
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
    }

    public var succeeded: Bool { status == 0 && !terminatedBySignal && !timedOut }
}

/// コマンドを流す。テストでは決まった結果を返すものに差し替える
public protocol CommandRunning: Sendable {
    func run(_ command: Command) async throws -> CommandResult
}

extension Command: CustomStringConvertible, CustomDebugStringConvertible {
    /// 環境変数は名前だけを出す（値に資格情報を含むことがあるため）
    public var description: String {
        let names = environment.keys.sorted()
        return "Command(\(executable.path), arguments: \(arguments.count) 個, environment: \(names), in: \(workingDirectory.path))"
    }

    public var debugDescription: String { description }
}
