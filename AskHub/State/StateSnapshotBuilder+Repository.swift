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

    /// 画面に出すビルドの設定と、直すときの元の JSON
    static func buildSettings(_ build: RepositoryFile.Build) -> RepositoryBuildSettings {
        RepositoryBuildSettings(
            scheme: build.xcode.scheme,
            destinations: build.xcode.destinations.map(Self.destinationName),
            childChecks: build.childChecks,
            finalChecks: build.finalChecks,
            json: ConfigureRepositoryIntent.payload(for: build)["build"].map(BuildSettingsDraft.pretty) ?? ""
        )
    }

    private static func destinationName(_ destination: BuildDestination) -> String {
        switch destination {
        case .macOS:
            "Mac"

        case .simulator(let simulator):
            simulator.osVersion.map { "\(simulator.deviceType)（\(simulator.platform.rawValue) \($0)）" } ?? simulator.deviceType
        }
    }

    /// 対象に加える・外す・ビルドの設定の呼び名。どれでもなければ nil
    static func repositoryLabel(_ envelope: IntentEnvelope) -> String? {
        switch envelope.kind {
        case AddRepositoryIntent.kind:
            "対象に加える（\(envelope.repo?.rawValue ?? "")）"

        case RemoveRepositoryIntent.kind:
            "対象から外す（\(envelope.repo?.rawValue ?? "")）"

        case ConfigureRepositoryIntent.kind:
            "ビルドの設定（\(envelope.repo?.rawValue ?? "")）"

        default:
            nil
        }
    }
}
