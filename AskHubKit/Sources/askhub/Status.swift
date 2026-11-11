import AskHubClient
import Foundation

extension AskHubMain {
    /// epic・質問・ゴール・着手前の確認の結果と、送った意図の処理の結果を出す
    static func status(_ arguments: CommandArguments) async throws {
        try arguments.only(["repo"])
        let repository = arguments.values["repo"] != nil ? try arguments.repository() : nil
        let connection = try connection()
        let report = try await StatusReport.render(connection.store, repository: repository, device: connection.key.keyID)
        if !report.isEmpty { print(report) }
    }
}
