import AskHubClient
import AskHubProtocol
import Foundation

// MARK: - 対象のリポジトリ

extension StateIntentMapper {
    /// 対象から外す（終わっていない epic が無い対象のリポジトリだけ）・ビルドの設定（対象のリポジトリだけ）を送れるか。片付けは、まだ送れない
    func supportsRepositoryIntent(_ intent: HumanIntent) -> Bool {
        switch intent {
        case .removeRepository(let repositoryID):
            index.repositories[repositoryID] != nil && !index.busyRepositories.contains(repositoryID)

        case let .configureRepository(repositoryID, _):
            index.repositories[repositoryID] != nil

        default:
            false
        }
    }

    func repositoryDraft(_ intent: HumanIntent) throws(ClientServiceError) -> IntentDraft {
        switch intent {
        case let .request(repositoryID, summary, body, files):
            guard summary.count <= RequestIntent.maximumTitleLength, body.count <= RequestIntent.maximumBodyLength else {
                let limits = "要約は \(RequestIntent.maximumTitleLength) 文字、内容は \(RequestIntent.maximumBodyLength) 文字まで"
                throw ClientServiceError(message: "\(limits)です")
            }
            // 司令塔は 1 から順の番号を求める（添付欄の順に振ったものを、そのまま送る）
            guard files.count <= RequestIntent.maximumAttachments, files.enumerated().allSatisfy({ $1.attachment.number == $0 + 1 }) else {
                throw ClientServiceError(message: "添付の番号が合いません。添付し直してください")
            }
            return .request(repo: try repository(repositoryID), title: summary, body: body, attachments: files.map(\.attachment))

        case .addRepository(let repositoryID):
            // 状態リポジトリにつないだときは候補の一覧が無いので、人が入れた owner/name を id にして送る。
            // 外したリポジトリは、外す前の owner/name の書き方で送る（状態リポジトリのパスは大文字小文字を区別する）
            let known = index.repositories[repositoryID] ?? index.removedRepositories[repositoryID]
            guard let repo = known ?? RepositoryFullName(rawValue: repositoryID) else {
                throw ClientServiceError(message: "owner/name の形で入れてください")
            }
            return .addRepository(repo)

        case .removeRepository(let repositoryID):
            guard !index.busyRepositories.contains(repositoryID) else {
                throw ClientServiceError(message: "進めている epic があるあいだは外せません。取り下げるか、終わってから外してください")
            }
            return .removeRepository(try repository(repositoryID))

        case let .configureRepository(repositoryID, json):
            return .configureRepository(try repository(repositoryID), build: try Self.build(json))

        default:
            throw Self.unsupported
        }
    }

    /// ビルドの設定の JSON を、司令塔と同じ決まりで読む（合わなければ送らない）
    static func build(_ json: String) throws(ClientServiceError) -> RepositoryFile.Build {
        let value: JSONValue
        do {
            value = try JSONValue(parsing: json)
        } catch {
            throw ClientServiceError(message: "JSON として読めません")
        }
        do {
            return try ConfigureRepositoryIntent.build(from: value)
        } catch {
            throw ClientServiceError(message: "ビルドの設定が決まりに合いません（\(error.detail)）")
        }
    }
}
