/// 設定ファイルを読み込めない理由。メッセージは CLI からそのまま表示する
public enum OrchestratorConfigError: Error, Equatable, CustomStringConvertible {
    case fileNotFound(path: String)
    case unreadable(path: String, reason: String)
    case invalidJSON(reason: String)
    case emptyTrustedAuthors
    case emptyOrg
    case noRepositories
    case invalidRepositoryName(String)
    case repositoryOutsideOrg(repository: String, org: String)
    case duplicateRepository(String)
    case relativeCheckoutPath(repository: String, path: String)
    case pollIntervalTooShort(seconds: Int, minimum: Int)
    case emptyLoopCommand
    case unknownPlaceholder(String)
    case emptyIdeaCommand
    case unknownIdeaPlaceholder(String)
    case ideaCommandWithoutPrompt

    public var description: String {
        switch self {
        case let .fileNotFound(path):
            "設定ファイルがありません: \(path)"
        case let .unreadable(path, reason):
            "設定ファイルを読めません: \(path)（\(reason)）"
        case let .invalidJSON(reason):
            "設定ファイルの JSON が不正です: \(reason)"
        case .emptyTrustedAuthors:
            "trustedAuthors が空です。指示として扱う GitHub アカウントを 1 つ以上指定してください"
        case .emptyOrg:
            "org が空です"
        case .noRepositories:
            "repositories が空です。担当リポジトリを 1 つ以上指定してください"
        case let .invalidRepositoryName(name):
            "repositories の repository は owner/repo の形式にしてください: \(name)"
        case let .repositoryOutsideOrg(repository, org):
            "担当リポジトリが org（\(org)）の外にあります: \(repository)"
        case let .duplicateRepository(name):
            "担当リポジトリが重複しています: \(name)"
        case let .relativeCheckoutPath(repository, path):
            "\(repository) の path は絶対パス（または ~ から始まるパス）にしてください: \(path)"
        case let .pollIntervalTooShort(seconds, minimum):
            "pollIntervalSeconds は \(minimum) 以上にしてください（指定: \(seconds)）"
        case .emptyLoopCommand:
            "loopCommand が空です。実行するコマンドを引数の配列で指定してください"
        case let .unknownPlaceholder(name):
            "loopCommand に未知のプレースホルダ {\(name)} があります（使えるもの: "
                + LoopCommandTemplate.Placeholder.allCases.map { "{\($0.rawValue)}" }.joined(separator: " ")
                + "）"

        case .emptyIdeaCommand:
            "ideaCommand が空です。実行するコマンドを引数の配列で指定してください"

        case let .unknownIdeaPlaceholder(name):
            "ideaCommand に未知のプレースホルダ {\(name)} があります（使えるもの: "
                + IdeaCommandTemplate.Placeholder.allCases.map { "{\($0.rawValue)}" }.joined(separator: " ")
                + "）"

        case .ideaCommandWithoutPrompt:
            "ideaCommand に {prompt} がありません。プロンプトを渡す引数に {prompt} を置いてください"
        }
    }
}
