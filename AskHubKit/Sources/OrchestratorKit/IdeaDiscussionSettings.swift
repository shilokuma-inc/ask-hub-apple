import Foundation

/// 依頼から Discussion を作る先のリポジトリの、Discussions の設定（Issue #719）
public struct DiscussionSettings: Sendable, Equatable {
    /// Discussions が有効か
    public let isEnabled: Bool
    /// Discussion のカテゴリの名前
    public let categories: [String]

    public init(isEnabled: Bool, categories: [String]) {
        self.isEnabled = isEnabled
        self.categories = categories
    }

    /// 質問付きの Discussion を作れない理由。作れるなら `nil`
    public var ideaProblem: IdeaDiscussionProblem? {
        if !isEnabled {
            return .disabled
        }
        return categories.contains(IdeaPrompt.category) ? nil : .missingCategory
    }
}

/// 依頼先のリポジトリで、質問付きの Discussion を作れない理由（副作用なし）
public enum IdeaDiscussionProblem: Sendable, Equatable {
    /// Discussions が無効で、オーケストレーターから有効にできない
    case disabled
    /// カテゴリ「Ideas」が無い
    case missingCategory

    /// 依頼 Issue に書く、理由と直し方
    public func message(for repository: String) -> String {
        switch self {
        case .disabled:
            "\(repository) の Discussions が無効で、オーケストレーターから有効にできませんでした（gh のトークンにリポジトリの管理者の権限が無いなど）。"
                + "GitHub のリポジトリの Settings → General → Features で Discussions を有効にしてください"

        case .missingCategory:
            "\(repository) の Discussions にカテゴリ「\(IdeaPrompt.category)」がありません。GitHub の Discussions でカテゴリ「\(IdeaPrompt.category)」を作ってください"
        }
    }
}
