import AskHubKit
import Foundation

/// 「新しいアプリ」の入力の既定値（プラットフォームごとの Organization）
extension IdeaRequestModel {
    /// プラットフォームを選んだときに既定で選ぶ Organization。
    /// そのプラットフォームの既定（visionOS は shilokuma-vision）が設定の一覧にあればそれ、無ければ一覧の先頭
    func defaultOrganization(for platform: NewRepository.Platform) -> String? {
        platform.organization(choosingFrom: organizationChoices)
    }

    /// プラットフォームの既定の Organization が設定の一覧に無いとき、その名前（足すよう案内する）。案内が要らなければ `nil`
    func missingDefaultOrganization(for platform: NewRepository.Platform) -> String? {
        guard let preferred = platform.defaultOrganization,
              !organizationChoices.contains(where: { $0.caseInsensitiveCompare(preferred) == .orderedSame }) else {
            return nil
        }
        return preferred
    }
}
