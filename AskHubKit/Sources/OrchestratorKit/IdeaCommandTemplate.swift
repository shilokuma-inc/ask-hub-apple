/// 依頼から Discussion を作らせるコマンド（既定は `claude` のヘッドレス実行）のテンプレート。
///
/// `LoopCommandTemplate` と同じく、シェルを経由せず引数の配列のまま実行する。
/// `{prompt}` に `IdeaPrompt` が組み立てたプロンプトが入る
public struct IdeaCommandTemplate: Sendable, Equatable {
    public enum Placeholder: String, CaseIterable, Sendable {
        /// `claude` に渡すプロンプト
        case prompt
        /// `owner/repo`
        case repository
        /// メインの checkout のパス
        case checkoutPath
    }

    /// 設定ファイルで省略したときの値。`gh` だけを許可して Discussion とコメントとラベルを作らせる
    public static let defaultArguments = ["claude", "-p", "{prompt}", "--allowedTools", "Bash(gh:*)"]

    public let arguments: [String]

    /// 既定のコマンド（`defaultArguments`）
    public static let standard = Self(validated: defaultArguments)

    private init(validated arguments: [String]) {
        self.arguments = arguments
    }

    /// 引数が空、`{prompt}` が無い、または未知の `{placeholder}` を含む場合は失敗する
    public init(arguments: [String] = defaultArguments) throws(OrchestratorConfigError) {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw .emptyIdeaCommand
        }
        let known = Set(Placeholder.allCases.map(\.rawValue))
        let names = arguments.flatMap(LoopCommandTemplate.placeholderNames(in:))
        if let unknown = names.first(where: { !known.contains($0) }) {
            throw .unknownIdeaPlaceholder(unknown)
        }
        guard names.contains(Placeholder.prompt.rawValue) else {
            throw .ideaCommandWithoutPrompt
        }
        self.arguments = arguments
    }

    public func render(prompt: String, for repository: RepositoryConfig) -> [String] {
        LoopCommandTemplate.substitute(arguments, values: [
            Placeholder.prompt.rawValue: prompt,
            Placeholder.repository.rawValue: repository.fullName,
            Placeholder.checkoutPath.rawValue: repository.checkoutPath
        ])
    }
}
