/// ループを起動するコマンドのテンプレート。
///
/// シェルを経由せず引数の配列のまま実行するため、値に空白や記号が含まれていても分割・展開されない。
/// 各引数の中の `{placeholder}` を、起動するリポジトリの値に置き換える。
public struct LoopCommandTemplate: Sendable, Equatable {
    /// テンプレートで使える値
    public enum Placeholder: String, CaseIterable, Sendable {
        /// `owner/repo`
        case repository
        /// メインの checkout のパス
        case checkoutPath
        /// 制御用 worktree のパス
        case controlPath
        /// ループのゴール元の Discussion の番号。Discussion を伴わない起動では空文字列
        case discussion
    }

    public let arguments: [String]

    /// 引数が空、または未知の `{placeholder}` を含む場合は失敗する（綴りの誤りを起動前に見つけるため）
    public init(arguments: [String]) throws(OrchestratorConfigError) {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw .emptyLoopCommand
        }
        let known = Set(Placeholder.allCases.map(\.rawValue))
        for argument in arguments {
            if let unknown = Self.placeholderNames(in: argument).first(where: { !known.contains($0) }) {
                throw .unknownPlaceholder(unknown)
            }
        }
        self.arguments = arguments
    }

    /// 担当リポジトリの値で置き換えた引数の配列を返す
    /// - Parameter discussionNumber: ゴール元の Discussion。`nil` なら `{discussion}` を空文字列にする
    public func render(for repository: RepositoryConfig, discussionNumber: Int? = nil) -> [String] {
        let values: [Placeholder: String] = [
            .repository: repository.fullName,
            .checkoutPath: repository.checkoutPath,
            .controlPath: repository.controlWorktreePath,
            .discussion: discussionNumber.map(String.init) ?? ""
        ]
        return Self.substitute(arguments, values: Dictionary(uniqueKeysWithValues: values.map { ($0.key.rawValue, $0.value) }))
    }

    /// 各引数の `{name}` を `values` で置き換える（`ideaCommand` でも使う）。
    /// 1 回の走査で置き換えるので、値（パスなど）に `{...}` が含まれていても再び置き換えない
    static func substitute(_ arguments: [String], values: [String: String]) -> [String] {
        arguments.map { argument in
            argument.replacing(placeholderPattern) { match in
                values[String(match.output.1)] ?? String(match.output.0)
            }
        }
    }

    /// `{name}`。name は英字のみ（JSON などの `{}` を誤検知しないため）。
    /// `Regex` は `Sendable` ではないので、static let で共有せず毎回作る
    private static var placeholderPattern: Regex<(Substring, Substring)> {
        /\{([A-Za-z]+)\}/
    }

    static func placeholderNames(in argument: String) -> [String] {
        argument.matches(of: placeholderPattern).map { String($0.output.1) }
    }
}
