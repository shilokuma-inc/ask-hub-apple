import Foundation

/// epic の最終 PR に第三者レビューをさせるコマンド（既定は `askhub-review-final`）と、
/// その `要修正` を直させるコマンド（既定は `askhub-fix-review`）と、CI の失敗を直させるコマンド（既定は `askhub-fix-ci`）のテンプレート（Discussion #503）。
///
/// `ConflictCommandTemplate` と同じく、シェルを経由せず引数の配列のまま実行する
public struct FinalReviewCommandTemplate: Sendable, Equatable {
    /// レビュー・修正・CI の修正のどのコマンドか
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// 第三者レビュー（`reviewCommand`）
        case review
        /// 第三者レビューの `要修正` の修正（`fixCommand`）
        case fix
        /// 失敗したジョブのログを読ませる CI の失敗の修正（`ciFixCommand`）
        case fixCI

        /// 起動スクリプトの名前。`install.sh` が `loopCommand` の起動スクリプトと同じ場所に置く
        public var scriptName: String {
            switch self {
            case .review:
                "askhub-review-final"

            case .fix:
                "askhub-fix-review"

            case .fixCI:
                "askhub-fix-ci"
            }
        }

        /// 終わるまで待つ上限。超えたら打ち切る。修正は CLAUDE.md の検証（ビルドとテスト）まで行うので、レビューより長く待つ
        public var timeout: Duration {
            switch self {
            case .review:
                .seconds(30 * 60)

            case .fix, .fixCI:
                .seconds(60 * 60)
            }
        }

        /// 設定ファイルのキー
        public var configKey: String {
            switch self {
            case .review:
                "reviewCommand"

            case .fix:
                "fixCommand"

            case .fixCI:
                "ciFixCommand"
            }
        }
    }

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
        /// レビュー・修正の対象として確認した head のコミット（目印の `sha` と、push の lease に使う）
        case headSHA
    }

    static let placeholderArguments = ["{repository}", "{checkoutPath}", "{headBranch}", "{baseBranch}", "{pullRequest}", "{headSHA}"]

    public let kind: Kind
    public let arguments: [String]

    private init(kind: Kind, validated arguments: [String]) {
        self.kind = kind
        self.arguments = arguments
    }

    /// 設定ファイルで省略したときの値。`loopCommand` の実行ファイルと同じディレクトリのスクリプトを使う
    /// （launchd の `PATH` は最小限なので、`loopCommand` が絶対パスならそれに揃える）
    public static func standard(_ kind: Kind, besides loopCommand: LoopCommandTemplate) -> Self {
        let executable = loopCommand.arguments.first ?? ""
        let script = executable.hasPrefix("/")
            ? URL(fileURLWithPath: executable).deletingLastPathComponent().appendingPathComponent(kind.scriptName).path
            : kind.scriptName
        return Self(kind: kind, validated: [script] + placeholderArguments)
    }

    /// 引数が空、または未知の `{placeholder}` を含む場合は失敗する
    public init(_ kind: Kind, arguments: [String]) throws(OrchestratorConfigError) {
        guard let executable = arguments.first, !executable.isEmpty else {
            throw .emptyFinalReviewCommand(key: kind.configKey)
        }
        let known = Set(Placeholder.allCases.map(\.rawValue))
        let names = arguments.flatMap(LoopCommandTemplate.placeholderNames(in:))
        if let unknown = names.first(where: { !known.contains($0) }) {
            throw .unknownFinalReviewPlaceholder(key: kind.configKey, name: unknown)
        }
        self.kind = kind
        self.arguments = arguments
    }

    public func render(for repository: RepositoryConfig, pullRequest: FinalReviewPullRequest) -> [String] {
        LoopCommandTemplate.substitute(arguments, values: [
            Placeholder.repository.rawValue: repository.fullName,
            Placeholder.checkoutPath.rawValue: repository.checkoutPath,
            Placeholder.headBranch.rawValue: pullRequest.headBranch,
            Placeholder.baseBranch.rawValue: pullRequest.baseBranch,
            Placeholder.pullRequest.rawValue: String(pullRequest.number),
            Placeholder.headSHA.rawValue: pullRequest.headSHA
        ])
    }
}

/// 第三者レビュー・修正の対象の最終 PR（`epic-final`）
public struct FinalReviewPullRequest: Sendable, Equatable {
    /// `owner/repo`
    public let repository: String
    public let number: Int
    /// epic のブランチ
    public let headBranch: String
    /// 既定ブランチ
    public let baseBranch: String
    /// レビュー・修正の対象として確認した head のコミット
    public let headSHA: String

    public init(repository: String, number: Int, headBranch: String, baseBranch: String, headSHA: String) {
        self.repository = repository
        self.number = number
        self.headBranch = headBranch
        self.baseBranch = baseBranch
        self.headSHA = headSHA
    }
}
