import AskHubProtocol
import Foundation

// MARK: - 対象に加える・外す

extension StateSnapshotBuilder {
    /// 対象に加える・外す。外したリポジトリを加え直すときは、外したものから戻す（アイコンなどはそのまま）
    func applyRepositoryIntent(
        _ envelope: IntentEnvelope,
        repositories: inout [TargetRepository],
        removed: inout [TargetRepository],
        index: inout StateIndex
    ) {
        guard let repo = envelope.repo else {
            return
        }
        let id = Self.repository(repo).id
        if envelope.kind == RemoveRepositoryIntent.kind {
            guard let offset = repositories.firstIndex(where: { $0.id == id }) else {
                return
            }
            removed.append(repositories.remove(at: offset))
            index.removedRepositories[id] = index.repositories.removeValue(forKey: id)
            return
        }
        guard index.repositories[id] == nil else {
            return
        }
        let restored = removed.first { $0.id == id } ?? Self.repository(repo)
        removed.removeAll { $0.id == id }
        repositories.append(restored)
        index.repositories[id] = index.removedRepositories.removeValue(forKey: id) ?? repo
    }

    /// 対象に加える・外すの呼び名。どちらでもなければ nil
    static func repositoryLabel(_ envelope: IntentEnvelope) -> String? {
        switch envelope.kind {
        case AddRepositoryIntent.kind:
            "対象に加える（\(envelope.repo?.rawValue ?? "")）"

        case RemoveRepositoryIntent.kind:
            "対象から外す（\(envelope.repo?.rawValue ?? "")）"

        default:
            nil
        }
    }
}
