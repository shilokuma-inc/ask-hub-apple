/// `askhub-orchestrator` のコマンドライン引数
public struct OrchestratorArguments: Sendable, Equatable {
    public static let usage = """
        usage: askhub-orchestrator [--config <path>]

        AskHub のオーケストレーター。設定ファイルに列挙した担当リポジトリを GitHub で監視し、
        ループの起動・再開などを行う。

        options:
          --config <path>  設定ファイルの場所（既定: ~/.config/askhub/orchestrator.json）
          -h, --help       この説明を表示する
        """

    /// 設定ファイルの場所。`nil` なら既定の場所
    public var configPath: String?
    public var showsHelp = false

    public init(configPath: String? = nil, showsHelp: Bool = false) {
        self.configPath = configPath
        self.showsHelp = showsHelp
    }

    /// 実行ファイル名を除いた引数を解析する
    public static func parse(_ arguments: some Sequence<String>) throws(ArgumentError) -> Self {
        var result = Self()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help":
                result.showsHelp = true
            case "--config":
                guard let path = iterator.next(), !path.isEmpty else {
                    throw .missingValue(option: argument)
                }
                result.configPath = path
            default:
                throw .unknownOption(argument)
            }
        }
        return result
    }

    public enum ArgumentError: Error, Equatable, CustomStringConvertible {
        case missingValue(option: String)
        case unknownOption(String)

        public var description: String {
            switch self {
            case let .missingValue(option):
                "\(option) には値が必要です"
            case let .unknownOption(option):
                "未知のオプションです: \(option)"
            }
        }
    }
}
