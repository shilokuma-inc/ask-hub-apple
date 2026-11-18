import AppIntents
import AskHubProtocol
import Foundation

/// Siri・ショートカットで選ぶ依頼先（対象のリポジトリ。外したものは出さない）
nonisolated struct RequestRepositoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "リポジトリ")
    static let defaultQuery = RequestRepositoryQuery()

    /// `owner/name`（状態リポジトリの `repo.json` の書き方）
    let id: String

    var displayRepresentation: DisplayRepresentation {
        guard let repo = RepositoryFullName(rawValue: id) else {
            return DisplayRepresentation(title: "\(id)")
        }
        return DisplayRepresentation(title: "\(repo.name)", subtitle: "\(repo.owner)")
    }
}

/// 依頼先の候補。状態リポジトリの対象のリポジトリを、アプリの「新しい依頼」の依頼先と同じ順で出す
nonisolated struct RequestRepositoryQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [RequestRepositoryEntity] {
        // 保存したショートカットの依頼先は、id だけから作る（ネットワークに出ない）。対象のままかは、送るときに確かめる
        identifiers.filter { RepositoryFullName(rawValue: $0) != nil }.map(RequestRepositoryEntity.init(id:))
    }

    func suggestedEntities() async throws -> [RequestRepositoryEntity] {
        try await ShortcutRequests().repositories().map { RequestRepositoryEntity(id: $0.rawValue) }
    }

    func entities(matching string: String) async throws -> [RequestRepositoryEntity] {
        try await suggestedEntities().filter { Self.matches($0.id, query: string) }
    }

    /// 名前の一部で探す。声で言った名前（「askhub sandbox」）でも当たるよう、大文字小文字と記号・空白の違いを無視する
    static func matches(_ id: String, query: String) -> Bool {
        let folded = fold(query)
        return folded.isEmpty || fold(id).contains(folded)
    }

    private static func fold(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
