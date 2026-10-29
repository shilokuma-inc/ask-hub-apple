/// `askhub-orchestrator` のコマンドライン引数
public struct OrchestratorArguments: Sendable, Equatable {
    public static let usage = """
        usage: askhub-orchestrator [--config <path>] [--once]
               askhub-orchestrator extract-zip <zip> <展開先>

        AskHub のオーケストレーター。設定ファイルに列挙した担当リポジトリを GitHub で監視し、
        ループの起動・再開などを行う。

        options:
          --config <path>  設定ファイルの場所（既定: ~/.config/askhub/orchestrator.json）
          --once           1 回だけポーリングして終了する
          -h, --help       この説明を表示する

        commands:
          extract-zip <zip> <展開先>
                           zip の添付を検査して展開し、結果をタブ区切りで出力する（ループの準備が使う）。
                           設定ファイルと GitHub のトークンは使わない
        """

    /// `extract-zip` のサブコマンドの引数
    public struct ExtractZip: Sendable, Equatable {
        public var zipPath: String
        public var destinationPath: String

        public init(zipPath: String, destinationPath: String) {
            self.zipPath = zipPath
            self.destinationPath = destinationPath
        }
    }

    /// 設定ファイルの場所。`nil` なら既定の場所
    public var configPath: String?
    /// 1 回だけポーリングして終了する（動作確認用）
    public var runsOnce = false
    public var showsHelp = false
    /// `extract-zip` のサブコマンド。`nil` ならオーケストレーターとして動く
    public var extractZip: ExtractZip?

    public init(configPath: String? = nil, runsOnce: Bool = false, showsHelp: Bool = false, extractZip: ExtractZip? = nil) {
        self.configPath = configPath
        self.runsOnce = runsOnce
        self.showsHelp = showsHelp
        self.extractZip = extractZip
    }

    /// 実行ファイル名を除いた引数を解析する
    public static func parse(_ arguments: some Sequence<String>) throws(ArgumentError) -> Self {
        let arguments = Array(arguments)
        if arguments.first == Self.extractZipCommand {
            return try parseExtractZip(arguments.dropFirst())
        }
        var result = Self()
        var iterator = arguments.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "-h", "--help":
                result.showsHelp = true
            case "--once":
                result.runsOnce = true
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

    static let extractZipCommand = "extract-zip"

    /// `extract-zip` の後ろは位置引数の 2 つだけ（パスが `-` で始まってもオプションとして読まない）。
    /// `-h` / `--help` だけなら、サブコマンドも載っている全体の説明を出す
    private static func parseExtractZip(_ arguments: ArraySlice<String>) throws(ArgumentError) -> Self {
        if arguments.count == 1, let only = arguments.first, only == "-h" || only == "--help" {
            return Self(showsHelp: true)
        }
        guard arguments.count == 2, let zip = arguments.first, let destination = arguments.last,
              !zip.isEmpty, !destination.isEmpty else {
            throw .invalidArguments(command: extractZipCommand, expected: "<zip> <展開先>")
        }
        return Self(extractZip: ExtractZip(zipPath: zip, destinationPath: destination))
    }

    public enum ArgumentError: Error, Equatable, CustomStringConvertible {
        case missingValue(option: String)
        case unknownOption(String)
        /// サブコマンドの位置引数の数が合わない・空の値がある
        case invalidArguments(command: String, expected: String)

        public var description: String {
            switch self {
            case let .missingValue(option):
                "\(option) には値が必要です"
            case let .unknownOption(option):
                "未知のオプションです: \(option)"
            case let .invalidArguments(command, expected):
                "\(command) の引数は \(expected) です"
            }
        }
    }
}
