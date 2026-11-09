import AskHubProtocol
import Foundation

extension GitHubPullRequests {
    /// 画像の添付の大きさの上限（GitHub の画像の添付は 10 MB まで）
    public static let maximumAttachmentBytes = 10 * 1024 * 1024

    /// 画像を GitHub に上げ、PR の本文から参照できる URL（`https://github.com/user-attachments/assets/…`）を返す。
    ///
    /// gh の `--attach` と同じ `user-attachments` の API（リポジトリへの書き込み権限が要る）。public のリポジトリでは誰でも見られ、
    /// 上げた画像は消せないので、デモのデータの画面だけを上げる
    public func uploadAttachment(_ payload: Data, name: String, contentType: String) async throws(PullRequestError) -> String {
        guard !payload.isEmpty, payload.count <= Self.maximumAttachmentBytes else { throw .invalidArgument("添付の大きさが 0 か、上限を超える") }
        guard name.wholeMatch(of: #/[A-Za-z0-9][A-Za-z0-9._-]{0,99}/#) != nil, contentType.wholeMatch(of: #/image/[a-z+.-]{1,30}/#) != nil else {
            throw .invalidArgument("添付の名前か種類の形が違う")
        }
        // `repos/<owner>/<repo>` そのもの（`api.url("")` だと末尾に `/` が付く）
        let repositoryURL = api.apiBase.appendingPathComponent("repos/\(repository.owner)/\(repository.name)")
        let (data, _) = try await api.send("GET", repositoryURL)
        let id = try GitHubAPI.decode(RepositoryIDPayload.self, from: data, what: "repos/\(repository.rawValue)").id
        var components = URLComponents(url: uploadsBase.appendingPathComponent("user-attachments/assets"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "content_type", value: contentType),
            URLQueryItem(name: "repository_id", value: String(id))
        ]
        guard let url = components?.url else { throw .invalidArgument("URL を作れない") }
        let body = try await api.upload(url, data: payload)
        let asset = try GitHubAPI.decode(AssetPayload.self, from: body, what: "user-attachments/assets")
        guard DecisionsFile.Screenshots.isAttachmentURL(asset.url) else { throw .malformed("添付の URL の形が違う") }
        return asset.url
    }

    /// PR の本文を書き換える
    public func updateBody(number: Int, body: String) async throws(PullRequestError) {
        try GitNames.checkNumber(number)
        _ = try await api.send("PATCH", api.url("pulls/\(number)"), body: UpdateBody(body: body))
    }
}

private struct RepositoryIDPayload: Decodable {
    let id: Int64
}

private struct AssetPayload: Decodable {
    let url: String
}

private struct UpdateBody: Encodable, Sendable {
    let body: String
}
