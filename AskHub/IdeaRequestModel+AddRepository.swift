import AskHubKit
import Foundation

/// 「担当に入れる」の入力の判断（入れるリポジトリに担当 PC がいるか）
extension IdeaRequestModel {
    /// 依頼先の一覧で、`repository` に担当 PC がいるか（担当の印が新しいか）。一覧に無ければ `false`。
    /// 担当 PC がいるリポジトリは入れる側のオーケストレーターが断るので、画面で先に知らせる
    func hasAssignedPC(_ repository: String, now: Date) -> Bool {
        repositories.first { $0.fullName == repository }?.isAssigned(now: now) ?? false
    }
}
