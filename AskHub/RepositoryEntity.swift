import AppIntents
import AskHubKit
import Foundation

/// Siri・ショートカットで選ぶ依頼先のリポジトリ（Discussion #655）
nonisolated struct RepositoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "リポジトリ")
    static let defaultQuery = RepositoryEntityQuery()

    /// `owner/repo`
    let id: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(id)")
    }
}

/// 依頼先の候補。アプリの依頼先の Picker と同じく、設定の organization のリポジトリすべてを出す
nonisolated struct RepositoryEntityQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RepositoryEntity] {
        // 保存されたショートカットの依頼先は id だけで作る（ネットワークに出ない）。形式の正しくない id は捨てる
        identifiers.filter(RepositoryName.isValidFullName).map(RepositoryEntity.init(id:))
    }

    func suggestedEntities() async throws -> [RepositoryEntity] {
        try await RepositoryCandidates().all(now: .now).map(RepositoryEntity.init(id:))
    }

    func entities(matching string: String) async throws -> [RepositoryEntity] {
        let candidates = try await RepositoryCandidates().all(now: .now)
        return RepositorySearch.filter(candidates, matching: string).map(RepositoryEntity.init(id:))
    }
}

/// App Intents から使う依頼先の候補の取り方。トークン・organization・requester の取り方はアプリの「新しい依頼」と同じ。テストでは差し替える
struct RepositoryCandidates {
    var tokenStore: any TokenStore = KeychainTokenStore.gitHub
    var makeRequester: (String) -> any IdeaRequesting = { GitHubIdeaRequester(client: GitHubClient(token: $0)) }
    var organizations: () -> [String] = { OrganizationSettings.load() }
    /// デモモードではトークンを読まず、GitHub に接続しない
    var usesSampleData: () -> Bool = { DemoMode.usesSampleData }

    /// 候補の `owner/repo`。アプリの依頼先の Picker（`RepositorySection.grouping`）と同じ順
    func all(now: Date) async throws -> [String] {
        let repositories: [RequestRepository]
        do {
            repositories = try await requester().repositories(in: organizations())
        } catch {
            throw AppIntentError(error)
        }
        return RepositorySection.grouping(repositories, now: now).flatMap(\.repositories)
    }

    private func requester() throws -> any IdeaRequesting {
        if usesSampleData() {
            return SampleIdeaRequester()
        }
        guard let token = try tokenStore.load() else {
            throw IdeaRequestModel.MissingTokenError()
        }
        return makeRequester(token)
    }
}

/// Siri・ショートカットに返す失敗。文言はアプリの「新しい依頼」と同じ（`IdeaRequestModel.message(for:)`）で、トークンの値は含めない
nonisolated struct AppIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String

    @MainActor
    init(_ error: any Error) {
        message = IdeaRequestModel.message(for: error)
    }

    var localizedStringResource: LocalizedStringResource {
        "\(message)"
    }
}
