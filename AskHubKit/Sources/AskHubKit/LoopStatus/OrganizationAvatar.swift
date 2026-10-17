import Foundation

/// organization のアバター画像の取得。ステータスタブの organization の節の見出しに出す。
///
/// 画像は公開されているので、**トークンを付けずに** `avatars.githubusercontent.com` から取る。
/// GitHub API 用のクライアント（`GitHubClient`）やセッション（`URLSession.uncached`）は使い回さず、
/// Cookie や資格情報を持たない専用のセッション（`URLSession.avatars`）で取る
public struct OrganizationAvatarFetcher: Sendable {
    private let http: any HTTPClient

    public init(http: any HTTPClient = URLSession.avatars) {
        self.http = http
    }

    /// アバター画像の URL（`https://avatars.githubusercontent.com/<login>?size=<px>`）。
    /// login に使えない文字（英数字とハイフン以外）を含む・空なら `nil`
    public static func url(login: String, pixelSize: Int) -> URL? {
        guard !login.isEmpty, login.unicodeScalars.allSatisfy(isLoginCharacter) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "avatars.githubusercontent.com"
        components.path = "/\(login)"
        components.queryItems = [URLQueryItem(name: "size", value: String(max(1, pixelSize)))]
        return components.url
    }

    /// 取得のリクエスト。`Authorization` ヘッダーは付けない
    public static func request(login: String, pixelSize: Int) -> URLRequest? {
        url(login: login, pixelSize: pixelSize).map { URLRequest(url: $0) }
    }

    /// 画像のデータを取る。200 以外・画像でない応答・空の応答は失敗にする
    public func imageData(login: String, pixelSize: Int) async throws -> Data {
        guard let request = Self.request(login: login, pixelSize: pixelSize) else {
            throw GitHubError.invalidResponse
        }
        let (data, response) = try await http.send(request)
        guard response.statusCode == 200 else {
            throw GitHubError.http(status: response.statusCode, message: nil)
        }
        let contentType = response.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard contentType.hasPrefix("image/"), !data.isEmpty else {
            throw GitHubError.invalidResponse
        }
        return data
    }

    private static func isLoginCharacter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-")
    }
}

extension URLSession {
    /// アバター画像の取得専用のセッション。Cookie・資格情報・ディスクのキャッシュを持たない（`ephemeral`）。
    /// GitHub API の認証付きの通信と混ぜないために分ける
    public static let avatars: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        return URLSession(configuration: configuration)
    }()
}
