import Foundation

/// epic の最終 PR のコンフリクトを解消させるコマンド（既定は `askhub-resolve-conflict`）のテンプレート。
///
/// `LoopCommandTemplate` と同じく、シェルを経由せず引数の配列のまま実行する
public struct ConflictCommandTemplate: Sendable, Equatable {
    public enum Placeholder: String, CaseIterable, Sendable {
        /// `owner/repo`
        case repository
        /// メインの checkout のパス
        case checkoutPath
        /// 最終 PR の head（epic のブランチ）
        case headBranch
        /// 最終 PR の base（既定ブランチ）
        case baseBranch
        /// 最終 PR の番号
        case pullRequest
    }

    /// 起動スクリプトの名前。`install.sh` が `loopCommand` の起動スクリプトと同じ場所に置く
    public static let scriptName = "askhub-resolve-conflict"
    static let placeholderArguments = ["{repository}", "{checkoutPath}", "{headBranch}", "{baseBranch}", "{pullRequest}"]

    public let arguments: [String]

    private init(validated arguments: [String]) {
        self.arguments = arguments
    }

    /// 設定ファイルで省略したときの値。`loopCommand` の実行ファイルと同じディレクトリの `askhub-resolve-conflict` を使う
    /// （launchd の `PATH` は最小限なので、`loopCommand` が絶対パスならそれに揃える）
    public static func standard(besides loopCommand: LoopCommandTemplate) -> Self {
        let executable = loopCommand.arguments.first ?? ""
        let script = executable.hasPrefix("/")
            ? URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent(scriptName).path
            : scriptName
        return Self(validated: [script] + placeholderArguments)
    }

    /// 引数が空、または未知の `{placeholder}` を含む場合は失敗する
    public init(arguments: [String]) throws(OrchestratorConfigError) {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw .emptyConflictCommand
        }
        let known = Set(Placeholder.allCases.map(\.rawValue))
        let names = arguments.flatMap(LoopCommandTemplate.placeholderNames(in:))
        if let unknown = names.first(where: { !known.contains($0) }) {
            throw .unknownConflictPlaceholder(unknown)
        }
        self.arguments = arguments
    }

    public func render(for repository: RepositoryConfig, pullRequest: ConflictingPullRequest) -> [String] {
        LoopCommandTemplate.substitute(arguments, values: [
            Placeholder.repository.rawValue: repository.fullName,
            Placeholder.checkoutPath.rawValue: repository.checkoutPath,
            Placeholder.headBranch.rawValue: pullRequest.headBranch,
            Placeholder.baseBranch.rawValue: pullRequest.baseBranch,
            Placeholder.pullRequest.rawValue: String(pullRequest.number)
        ])
    }
}
