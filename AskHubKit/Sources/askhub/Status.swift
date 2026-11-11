import AskHubClient
import Foundation

extension AskHubMain {
    /// epic・質問・ゴール・着手前の確認の結果と、送った意図の処理の結果を出す。`--watch <秒>` なら、その間隔で読み直し、変わったときだけ出す
    static func status(_ arguments: CommandArguments) async throws {
        try arguments.only(["repo", "watch"])
        let repository = arguments.values["repo"] != nil ? try arguments.repository() : nil
        let interval = try StatusWatch.interval(arguments)
        let connection = try connection()
        let (store, device) = (connection.store, connection.key.keyID)
        let read: @Sendable () async throws -> String = {
            try await StatusReport.render(store, repository: repository, device: device)
        }
        guard let interval else {
            let report = try await read()
            if !report.isEmpty { print(report) }
            return
        }
        let watch = StatusWatch(
            interval: interval,
            read: read,
            // 裏で流して出力をファイルで見るときも周ごとに届くよう、溜めずに書く
            output: { FileHandle.standardOutput.write(Data("\($0)\n".utf8)) },
            problem: { FileHandle.standardError.write(Data("askhub: \($0)\n".utf8)) }
        )
        try await watch.run()
    }
}
