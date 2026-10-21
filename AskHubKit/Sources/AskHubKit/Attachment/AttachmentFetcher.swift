import CryptoKit
import Foundation

/// 目印が指す添付の中身を取る。テストでは差し替える
public protocol AttachmentFetching: Sendable {
    /// `marker` の blob SHA で `repository`（`owner/repo`）から中身を取り、大きさと SHA が目印と合うことを確かめて返す
    func fetch(_ marker: AttachmentMarker, from repository: String) async throws -> Data
}

/// 添付を取れない・使えないときのエラー。トークンの値は含めない
public enum AttachmentFetchError: Error, Equatable, Sendable {
    /// 目印の形が誤っている（`AttachmentMarker.isWellFormed` でない）
    case malformedMarker
    /// blob が見つからない、またはリポジトリが見えない（GitHub の 404）
    case notFound
    /// 応答の中身を base64 として読めない
    case invalidContent
    /// 取った中身の大きさが目印の `size` と合わない
    case sizeMismatch(expected: Int, actual: Int)
    /// 取った中身の git の blob SHA が目印の `sha` と合わない
    case shaMismatch
}

/// git の blob SHA（`"blob <バイト数>\0"` + 内容の SHA-1。40 桁の小文字の 16 進）
public enum GitBlobSHA {
    public static func of(_ data: Data) -> String {
        var hash = Insecure.SHA1()
        hash.update(data: Data("blob \(data.count)\0".utf8))
        hash.update(data: data)
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// GitHub の Git Data API（`GET repos/{owner}/{repo}/git/blobs/{sha}`）で添付を取る
/// （`docs/protocol.md` の「添付ファイル」の「読み方」）。
///
/// ブランチのパスからは読まない（ブランチ上のファイルは書き込み権限があれば変えられるため、目印の blob SHA で取る）。
/// 取った中身の大きさと blob SHA が目印と合わなければ使わない
public struct GitHubAttachmentFetcher: AttachmentFetching {
    private let client: GitHubClient

    public init(client: GitHubClient) {
        self.client = client
    }

    public func fetch(_ marker: AttachmentMarker, from repository: String) async throws -> Data {
        guard marker.isWellFormed else {
            throw AttachmentFetchError.malformedMarker
        }
        let blob: BlobResponse
        do {
            blob = try await client.get("repos/\(repository)/git/blobs/\(marker.sha)", as: BlobResponse.self)
        } catch GitHubError.http(status: 404, _) {
            throw AttachmentFetchError.notFound
        }
        // 取る前に大きさを確かめ、目印と合わない大きな中身を戻さない
        if let size = blob.size, size != marker.size {
            throw AttachmentFetchError.sizeMismatch(expected: marker.size, actual: size)
        }
        // GitHub の応答の base64 には 60 文字ごとに改行が入る
        guard blob.encoding == "base64",
              let data = Data(base64Encoded: blob.content, options: .ignoreUnknownCharacters) else {
            throw AttachmentFetchError.invalidContent
        }
        guard data.count == marker.size else {
            throw AttachmentFetchError.sizeMismatch(expected: marker.size, actual: data.count)
        }
        guard GitBlobSHA.of(data) == marker.sha else {
            throw AttachmentFetchError.shaMismatch
        }
        return data
    }
}

private struct BlobResponse: Decodable {
    let content: String
    let encoding: String
    let size: Int?
}
