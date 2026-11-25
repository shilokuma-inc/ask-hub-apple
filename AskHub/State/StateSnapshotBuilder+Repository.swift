import AskHubProtocol
import Foundation

// MARK: - 対象に加える・外す

extension StateSnapshotBuilder {
    /// 対象に加える・外す・テンプレートから作る。外したリポジトリを加え直すときは、外したものから戻す（アイコンなどはそのまま）
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
        var restored = removed.first { $0.id == id } ?? Self.repository(repo)
        // テンプレートから作るものは、司令塔が作る前から、選んだアプリ名で出す
        if let create = try? CreateRepositoryIntent(envelope: envelope) {
            restored.appName = create.appName
        } else if restored.appName == repo.name, let name = appStoreName(of: repo) {
            restored.appName = name
        }
        removed.removeAll { $0.id == id }
        repositories.append(restored)
        index.repositories[id] = index.removedRepositories.removeValue(forKey: id) ?? repo
    }

    /// アプリ名を付けた対象のリポジトリ。テンプレートから作ったときのアプリ名が無ければ、
    /// App Store の準備の記録（`app-store.json`）にある App Store Connect のアプリ名を使う（どちらも無ければリポジトリ名）
    func namedRepository(_ file: RepositoryFile) -> TargetRepository {
        var repository = Self.repository(file)
        if file.created?.appName == nil, let name = appStoreName(of: file.repo) {
            repository.appName = name
        }
        return repository
    }

    /// App Store の準備の記録にある App Store Connect のアプリ名。記録が無い・アプリがまだ無い・名前が空なら nil。
    /// 記録の `repo` は司令塔が書いた書き方のままなので、大文字小文字をそろえて照らし合わせる
    func appStoreName(of repo: RepositoryFullName) -> String? {
        let setup = documents.appStoreSetups.first { $0.repo.rawValue.lowercased() == repo.rawValue.lowercased() }
        guard let name = setup?.app?.name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return name
    }

    /// 画面に出すビルドの設定と、直すときの元の JSON
    static func buildSettings(_ build: RepositoryFile.Build) -> RepositoryBuildSettings {
        RepositoryBuildSettings(
            scheme: build.xcode.scheme,
            destinations: build.xcode.destinations.map(Self.destinationName),
            childChecks: build.childChecks,
            finalChecks: build.finalChecks,
            json: ConfigureRepositoryIntent.payload(for: build)["build"].map(BuildSettingsDraft.pretty) ?? "",
            hasStoreScreenshots: build.storeScreenshots != nil
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

        case CreateRepositoryIntent.kind:
            "新しいアプリ（\(envelope.repo?.rawValue ?? "")）"

        case ReadSecretsKeyIntent.kind:
            "Secrets の公開鍵を読む（\(envelope.repo?.rawValue ?? "")）"

        case RemoveRepositoryIntent.kind:
            "対象から外す（\(envelope.repo?.rawValue ?? "")）"

        case ConfigureRepositoryIntent.kind:
            "ビルドの設定（\(envelope.repo?.rawValue ?? "")）"

        default:
            nil
        }
    }
}
