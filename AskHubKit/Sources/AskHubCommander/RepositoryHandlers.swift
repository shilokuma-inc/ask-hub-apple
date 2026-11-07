import AskHubProtocol
import AskHubStateStore
import Foundation

/// ビルドの設定を入れる（`configureRepository`）を受け付け、`repo.json` の `build` を置き換える。
/// 対象に加えていないリポジトリには書かない（`repo.json` を作るのは「対象に加える」だけ）
public struct ConfigureRepositoryHandler: IntentHandler {
    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let configure: ConfigureRepositoryIntent
        do {
            configure = try ConfigureRepositoryIntent(envelope: envelope)
        } catch {
            return .reject("ビルドの設定の形が違う（\(error.detail)）")
        }
        let path = StatePath.repository(configure.repo)
        guard try await context.read(RepositoryFile.self, at: path) != nil else {
            return .reject("\(configure.repo) は対象のリポジトリに加えていない。先に対象に加える")
        }
        do {
            try await context.files.update(RepositoryFile.self, at: path, message: "\(configure.repo) のビルドの設定を書く") {
                // 同じ設定なら書かない（やり直したとき）
                guard $0.build != configure.build else { return false }
                $0.build = configure.build
                return true
            }
        } catch {
            throw .files(error)
        }
        return .accept
    }
}
