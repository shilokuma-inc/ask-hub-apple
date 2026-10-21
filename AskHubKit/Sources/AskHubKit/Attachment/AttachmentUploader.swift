import Foundation

/// アップロードする添付 1 つ（選んだファイルの中身）。送るまで GitHub には上げない
public struct AttachmentFile: Sendable, Equatable, Hashable {
    /// 元のファイル名
    public var name: String
    /// MIME タイプ（例: `image/png`）
    public var type: String
    public var data: Data

    public init(name: String, type: String, data: Data) {
        self.name = name
        self.type = type
        self.data = data
    }
}

/// 添付を依頼先のリポジトリに上げ、本文に置く目印を返す。テストでは差し替える
public protocol AttachmentUploading: Sendable {
    /// `files` を順に `repository`（`owner/repo`）の `askhub/attachments` ブランチへ上げる。
    /// 1 つでも上げられなければエラーにする（それまでに上げた分は返さない）
    func upload(_ files: [AttachmentFile], to repository: String) async throws -> [AttachmentMarker]
}

/// 添付を上げられないときのエラー。アプリはこれを文言にする（トークンの値は含めない）
public enum AttachmentUploadError: Error, Equatable, Sendable {
    /// トークンに依頼先の Contents の書き込み権限が無い、または依頼先が見えない（GitHub の 403 / 404）
    case missingContentsPermission
    /// ブランチが何度も先に進み、上げられなかった（409 が続いた）
    case conflict
}

/// GitHub の Contents API で、依頼先のリポジトリの `askhub/attachments` ブランチへ添付を上げる
/// （`docs/protocol.md` の「添付ファイル」の「アップロード」）。トークンには依頼先の Contents の書き込み権限が要る。
///
/// - ファイルは 1 つずつ順に上げる（同じブランチへの同時のコミットは 409 になるため）
/// - ブランチが無ければ、親の無いブランチ（`README.md` だけ）を Git Data API で作ってから上げ直す
/// - 409（ブランチが先に進んだ）は `maxConflictRetries` 回まで再試行する
public struct GitHubAttachmentUploader: AttachmentUploading {
    /// 409 の再試行の回数
    public static let maxConflictRetries = 3

    private let client: GitHubClient
    private let makeID: @Sendable () -> UUID

    /// - Parameter makeID: 添付ごとの UUID。テストでは決まった値を返す
    public init(client: GitHubClient, makeID: @escaping @Sendable () -> UUID = { UUID() }) {
        self.client = client
        self.makeID = makeID
    }

    public func upload(_ files: [AttachmentFile], to repository: String) async throws -> [AttachmentMarker] {
        var markers: [AttachmentMarker] = []
        for file in files {
            markers.append(try await upload(file, to: repository))
        }
        return markers
    }

    private func upload(_ file: AttachmentFile, to repository: String) async throws -> AttachmentMarker {
        let path = AttachmentMarker.path(id: makeID(), fileName: file.name)
        var conflicts = 0
        var createdBranch = false
        while true {
            do {
                let response = try await put(file, path: path, in: repository)
                return AttachmentMarker(
                    path: path,
                    sha: response.content.sha,
                    commit: response.commit.sha,
                    name: file.name,
                    size: file.data.count,
                    type: file.type
                )
            } catch GitHubError.http(status: 409, _) where conflicts < Self.maxConflictRetries {
                conflicts += 1
            } catch GitHubError.http(status: 409, _) {
                throw AttachmentUploadError.conflict
            } catch let GitHubError.http(status, message) where status == 404 || status == 422 {
                // ブランチが無いと、GitHub は 404 か 422 で断る。ブランチがあるかを確かめ、無ければ作ってから上げ直す
                let failure = Self.mapped(GitHubError.http(status: status, message: message))
                if createdBranch {
                    throw failure
                }
                if try await branchExists(in: repository) {
                    throw failure
                }
                try await createBranch(in: repository)
                createdBranch = true
            } catch {
                throw Self.mapped(error)
            }
        }
    }

    private func put(_ file: AttachmentFile, path: String, in repository: String) async throws -> PutContentResponse {
        try await client.send(
            "PUT",
            "repos/\(repository)/contents/\(path)",
            body: PutContentRequest(
                message: "[chore] 添付を追加: \(AttachmentFileName.sanitized(file.name))",
                content: file.data,
                branch: AttachmentMarker.branch
            ),
            as: PutContentResponse.self
        )
    }

    /// `askhub/attachments` があるか。404 なら無い。リポジトリが見えないときも 404 なので、続くブランチの作成で権限のエラーになる
    private func branchExists(in repository: String) async throws -> Bool {
        do {
            _ = try await client.get("repos/\(repository)/git/ref/heads/\(AttachmentMarker.branch)", as: GitRef.self)
            return true
        } catch GitHubError.http(status: 404, _) {
            return false
        } catch {
            throw Self.mapped(error)
        }
    }

    /// 親の無いブランチを作る（tree → commit（`parents: []`）→ ref）。同時に作られて ref が既にある（422）なら、そのまま使う
    private func createBranch(in repository: String) async throws {
        do {
            let tree = try await client.send(
                "POST",
                "repos/\(repository)/git/trees",
                body: CreateTreeRequest(tree: [
                    CreateTreeRequest.Entry(path: "README.md", mode: "100644", type: "blob", content: Self.readme)
                ]),
                as: GitObject.self
            )
            let commit = try await client.send(
                "POST",
                "repos/\(repository)/git/commits",
                body: CreateCommitRequest(message: "[chore] AskHub の添付を置くブランチを作る", tree: tree.sha, parents: []),
                as: GitObject.self
            )
            do {
                try await client.send(
                    "POST",
                    "repos/\(repository)/git/refs",
                    body: CreateRefRequest(ref: "refs/heads/\(AttachmentMarker.branch)", sha: commit.sha)
                )
            } catch GitHubError.http(status: 422, _) {
                // ほかの送信が先にブランチを作った
            }
        } catch {
            throw Self.mapped(error)
        }
    }

    /// 403 / 404 は Contents の書き込み権限が無い旨のエラーにする。それ以外（レート制限など）はそのまま返す
    private static func mapped(_ error: any Error) -> any Error {
        switch error {
        case GitHubError.http(status: 403, _), GitHubError.http(status: 404, _):
            AttachmentUploadError.missingContentsPermission

        default:
            error
        }
    }

    /// ブランチの最初のコミットに置く説明
    static let readme = """
        # askhub/attachments

        AskHub（https://github.com/shilokuma-inc/ask-hub-apple）が、依頼・回答・実機確認の「問題あり」に添付したファイルを置くブランチです。
        ファイルは依頼や回答の本文の目印（`ask-hub:attachment`）から blob SHA で読みます。

        - 開発には使いません。このブランチをマージしたり、手でファイルを消したりしないでください
        - epic の最終 PR がマージされると、オーケストレーターがその epic の添付を消します（git の履歴には残ります）
        - public のリポジトリでは、ここに置いたファイルは誰でも見られます

        """
}

private struct PutContentRequest: Encodable, Sendable {
    let message: String
    /// `JSONEncoder` の既定で base64 の文字列になる
    let content: Data
    let branch: String
}

private struct PutContentResponse: Decodable {
    struct Content: Decodable {
        let sha: String
    }

    struct Commit: Decodable {
        let sha: String
    }

    let content: Content
    let commit: Commit
}

private struct GitRef: Decodable {
    let ref: String
}

private struct GitObject: Decodable {
    let sha: String
}

private struct CreateTreeRequest: Encodable, Sendable {
    struct Entry: Encodable, Sendable {
        let path: String
        let mode: String
        let type: String
        let content: String
    }

    let tree: [Entry]
}

private struct CreateCommitRequest: Encodable, Sendable {
    let message: String
    let tree: String
    let parents: [String]
}

private struct CreateRefRequest: Encodable, Sendable {
    let ref: String
    let sha: String
}
