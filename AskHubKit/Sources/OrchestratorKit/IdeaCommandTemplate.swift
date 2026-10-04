/// 依頼から Discussion を作らせるコマンド（既定は `claude` のヘッドレス実行）のテンプレート。
///
/// `LoopCommandTemplate` と同じく、シェルを経由せず引数の配列のまま実行する。
/// `IdeaPrompt` が組み立てたプロンプトは標準入力で渡す（依頼の本文をプロセスの引数に出さないため）
public struct IdeaCommandTemplate: Sendable, Equatable {
    public enum Placeholder: String, CaseIterable, Sendable {
        /// `owner/repo`
        case repository
        /// メインの checkout のパス
        case checkoutPath
    }

    /// 設定ファイルで省略したときの値。プロンプトを標準入力から読ませ、`gh` だけを許可して Discussion とコメントとラベルを作らせる
    public static let defaultArguments = ["claude", "-p", "--allowedTools", "Bash(gh:*)"]

    public let arguments: [String]

    /// 既定のコマンド（`defaultArguments`）
    public static let standard = Self(validated: defaultArguments)

    private init(validated arguments: [String]) {
        self.arguments = arguments
    }

    /// 引数が空、または未知の `{placeholder}` を含む場合は失敗する
    public init(arguments: [String] = defaultArguments) throws(OrchestratorConfigError) {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw .emptyIdeaCommand
        }
        let known = Set(Placeholder.allCases.map(\.rawValue))
        let names = arguments.flatMap(LoopCommandTemplate.placeholderNames(in:))
        if let unknown = names.first(where: { !known.contains($0) }) {
            throw .unknownIdeaPlaceholder(unknown)
        }
        self.arguments = arguments
    }

    public func render(for repository: RepositoryConfig) -> [String] {
        LoopCommandTemplate.substitute(arguments, values: [
            Placeholder.repository.rawValue: repository.fullName,
            Placeholder.checkoutPath.rawValue: repository.checkoutPath
        ])
    }
}
