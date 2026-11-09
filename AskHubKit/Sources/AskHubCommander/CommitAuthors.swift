import AskHubStateStore
import Foundation

/// ワーカーが作るコミットの書き手（git の `user.name`・`user.email`。author と committer の両方）
public struct GitAuthor: Sendable, Equatable {
    public var name: String
    public var email: String

    public init(name: String, email: String) {
        self.name = name
        self.email = email
    }

    /// アカウントが分からないときの書き手。`.invalid` は誰のものにもならないドメイン（RFC 2606）なので、GitHub の誰かのアカウントに結び付かない
    public static let fallback = GitAuthor(name: "AskHub", email: "worker@askhub.invalid")

    /// GitHub のアカウントの書き手。本当のメールアドレスを出さずにアカウントに結び付くよう、noreply アドレス（`<id>+<login>@users.noreply.github.com`）にする。
    /// 名前はプロフィールの名前。git が書き手の区切りに使う文字（`<`・`>`）と制御文字は除き、
    /// git が名前として受け付けない形（空白と `.`・`,`・`:`・`;`・`"`・`'`・`\` だけ）なら login にする（コミットが断られないように）
    public static func account(id: Int, login: String, name: String?) -> GitAuthor {
        let isControl = { (character: Character) in character.unicodeScalars.contains { $0.properties.generalCategory == .control } }
        let profile: String = name ?? ""
        let cleaned = profile.filter { !"<>".contains($0) && !isControl($0) }.trimmingCharacters(in: .whitespaces)
        let usable = cleaned.contains { !$0.isWhitespace && !".,:;\"'\\".contains($0) }
        return GitAuthor(name: usable ? cleaned : login, email: "\(id)+\(login)@users.noreply.github.com")
    }
}

/// リポジトリの持ち主ごとの、コミットの書き手
public protocol CommitAuthors: Sendable {
    func author(for owner: String) async -> GitAuthor
}

/// いつも同じ書き手（テストと、GitHub のアカウントを読まない使い方）
public struct FixedCommitAuthor: CommitAuthors {
    public var author: GitAuthor

    public init(_ author: GitAuthor = .fallback) {
        self.author = author
    }

    public func author(for owner: String) async -> GitAuthor {
        author
    }
}

/// リポジトリの持ち主に使う GitHub のトークンの持ち主（GitHub のアカウント）を、コミットの書き手にする（ユーザーの決定。PR を開く・マージするアカウントとそろえる）。
///
/// `GET /user`（fine-grained token でも権限なしで読める）で読み、持ち主ごとに覚える。
/// 読めないとき（トークンが無い・つながらない・GitHub の障害）は覚えずに `GitAuthor.fallback` を返し、次のコミットで読み直す。
/// トークンの値は `Authorization` にだけ入れ、ログ・URL・エラーに出さない
public actor GitHubCommitAuthors: CommitAuthors {
    private let token: @Sendable (_ owner: String) async throws -> String
    private let transport: any HTTPTransport
    private let apiBase: URL
    private let log: @Sendable (String) -> Void
    private var known: [String: GitAuthor] = [:]

    public init(
        token: @escaping @Sendable (_ owner: String) async throws -> String,
        transport: any HTTPTransport = GitHubURLSessionTransport(),
        apiBase: URL = URL(string: "https://api.github.com")!,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.token = token
        self.transport = transport
        self.apiBase = apiBase
        self.log = log
    }

    public func author(for owner: String) async -> GitAuthor {
        if let author = known[owner] { return author }
        guard let author = await account(for: owner) else {
            log("\(owner) のトークンの持ち主を読めなかったので、コミットの書き手を \(GitAuthor.fallback.name) にした")
            return .fallback
        }
        known[owner] = author
        return author
    }

    private struct User: Decodable {
        let id: Int
        let login: String
        let name: String?
    }

    private func account(for owner: String) async -> GitAuthor? {
        guard let token = try? await token(owner) else { return nil }
        var request = URLRequest(url: apiBase.appendingPathComponent("user"))
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await transport.send(request),
              (200..<300).contains(response.statusCode),
              let user = try? JSONDecoder().decode(User.self, from: data),
              user.id > 0, Self.isLogin(user.login) else {
            return nil
        }
        return .account(id: user.id, login: user.login, name: user.name)
    }

    /// GitHub の login の形（英数字とハイフン）。noreply アドレスに入れるので、ほかの文字を通さない
    static func isLogin(_ login: String) -> Bool {
        !login.isEmpty && login.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
