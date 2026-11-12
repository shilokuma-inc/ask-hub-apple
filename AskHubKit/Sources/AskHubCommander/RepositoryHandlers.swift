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
        guard let repository = try await context.read(RepositoryFile.self, at: path) else {
            return .reject("\(configure.repo) は対象のリポジトリに加えていない。先に対象に加える")
        }
        guard !repository.isRemoved else { return .reject("\(configure.repo) は対象から外した。設定するには加え直す") }
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

/// 対象から外す（`removeRepository`）を受け付け、`repo.json` に外した印（`removedAt`）を付ける。
/// 終わっていない epic（マージした・やめた epic のほか）があれば断る（先に取り下げるか、終わるのを待ってもらう）。
/// 状態リポジトリのファイルは消さず、GitHub 側（ルールセット・Discussions・ワークフロー）には触れない。加え直すと印を外して戻る
public struct RemoveRepositoryHandler: IntentHandler {
    /// 終わった epic の段階。ほかの段階の epic があれば外さない
    static let finishedStages: Set<EpicStage> = [.merged, .abandoned]

    public init() {}

    public func handle(_ envelope: IntentEnvelope, in context: CommanderContext) async throws(CommanderError) -> IntentDecision {
        let remove: RemoveRepositoryIntent
        do {
            remove = try RemoveRepositoryIntent(envelope: envelope)
        } catch {
            return .reject("対象から外す意図の形が違う（\(error.detail)）")
        }
        let path = StatePath.repository(remove.repo)
        guard let repository = try await context.read(RepositoryFile.self, at: path) else {
            return .reject("\(remove.repo) は対象のリポジトリに加えていない")
        }
        // 前の周で外した（やり直し）か、もう外している
        if repository.isRemoved { return .accept }
        let unfinished = try await context.epics(of: remove.repo) { !Self.finishedStages.contains($0.stage) }
        if !unfinished.isEmpty {
            let names = unfinished.map { "「\($0.title)」（\($0.stage.rawValue)）" }.joined(separator: "・")
            return .reject("終わっていない epic がある: \(names)。取り下げるか、終わってから外す")
        }
        do {
            try await context.files.update(RepositoryFile.self, at: path, message: "\(remove.repo) を対象から外す") {
                guard !$0.isRemoved else { return false }
                $0.removedAt = context.timestamp
                return true
            }
        } catch {
            throw .files(error)
        }
        return .accept
    }
}
