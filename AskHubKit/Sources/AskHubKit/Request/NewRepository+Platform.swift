import Foundation

extension NewRepository {
    /// 新しいアプリのプラットフォーム。画面では先にこれを選び、次にそのプラットフォームのテンプレートを選ぶ。
    /// 依頼の目印の `platform` の値は `rawValue`
    public enum Platform: String, Sendable, CaseIterable, Identifiable {
        case iOS = "ios"
        case visionOS = "visionos"

        public var id: String {
            rawValue
        }

        /// 画面に出す名前
        public var title: String {
            switch self {
            case .iOS: "iOS"
            case .visionOS: "visionOS"
            }
        }

        /// このプラットフォームのテンプレート（`Template.allCases` の並び順）
        public var templates: [Template] {
            Template.allCases.filter { $0.platform == self }
        }

        /// 既定で作成先にする organization（テンプレートのある organization）。無ければ `nil`
        public var defaultOrganization: String? {
            switch self {
            case .iOS: nil
            case .visionOS: "shilokuma-vision"
            }
        }

        /// リポジトリ名の例に付ける接尾辞
        public var repositoryNameSuffix: String {
            "-\(rawValue)"
        }

        /// 作成先の候補（設定の Organization の一覧）から、このプラットフォームで既定に選ぶもの。
        /// `defaultOrganization` が候補にあればそれ（候補の表記のまま）を、無ければ候補の先頭を返す
        public func organization(choosingFrom choices: [String]) -> String? {
            if let preferred = defaultOrganization,
               let match = choices.first(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) {
                return match
            }
            return choices.first
        }
    }

    /// テンプレートから決まるプラットフォーム
    public var platform: Platform {
        template.platform
    }
}

extension NewRepository.Template {
    /// このテンプレートのプラットフォーム
    public var platform: NewRepository.Platform {
        switch self {
        case .standard, .quiz: .iOS
        case .visionOSStandard: .visionOS
        }
    }

    /// プラットフォームを添えた名前（例: 「visionOS の通常」）。Issue の本文・結果のコメント・送った依頼に使う
    public var qualifiedTitle: String {
        "\(platform.title) の\(title)"
    }
}
