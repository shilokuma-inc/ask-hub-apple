@testable import AskHubCommander
import Foundation
import os
import Testing

/// ワーカーのコミットの書き手を、リポジトリの持ち主に使う GitHub のトークンの持ち主にする
struct CommitAuthorsTests {
    static let token = "github_pat_" + String(repeating: "a", count: 40)
    static let user = StubTransport.Reply.json(200, #"{"id":1234,"login":"mrs1669","name":"Takumi Muraishi","email":"secret@example.com"}"#)

    func authors(_ transport: StubTransport, logs: OSAllocatedUnfairLock<[String]> = .init(initialState: [])) -> GitHubCommitAuthors {
        GitHubCommitAuthors(
            token: { owner in
                guard owner == "shilokuma-inc" else { throw URLError(.userAuthenticationRequired) }
                return Self.token
            },
            transport: transport,
            log: { message in logs.withLock { $0.append(message) } }
        )
    }

    @Test func usesNoreplyAddressOfTokenOwnerWithoutExposingToken() async throws {
        let transport = StubTransport([Self.user])
        let author = await authors(transport).author(for: "shilokuma-inc")
        // 本当のメールアドレス（`email`）ではなく、noreply アドレスにする
        #expect(author == GitAuthor(name: "Takumi Muraishi", email: "1234+mrs1669@users.noreply.github.com"))
        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString == "https://api.github.com/user")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.token)")
        #expect(request.url?.absoluteString.contains(Self.token) == false)
    }

    @Test func remembersAuthorPerOwner() async {
        let transport = StubTransport([Self.user])
        let authors = authors(transport)
        _ = await authors.author(for: "shilokuma-inc")
        #expect(await authors.author(for: "shilokuma-inc").email == "1234+mrs1669@users.noreply.github.com")
        #expect(transport.requests.count == 1)
    }

    @Test func readsAgainWhenTokenIsReplaced() async {
        let current = OSAllocatedUnfairLock(initialState: "github_pat_" + String(repeating: "a", count: 40))
        let other = StubTransport.Reply.json(200, #"{"id":99,"login":"someone","name":null}"#)
        let transport = StubTransport([Self.user, other])
        let authors = GitHubCommitAuthors(token: { _ in current.withLock { $0 } }, transport: transport)
        #expect(await authors.author(for: "shilokuma-inc").email == "1234+mrs1669@users.noreply.github.com")
        // 同じトークンなら聞き直さない
        #expect(await authors.author(for: "shilokuma-inc").email == "1234+mrs1669@users.noreply.github.com")
        #expect(transport.requests.count == 1)
        // 入れ替えたら、新しいトークンの持ち主を読み直す
        current.withLock { $0 = "github_pat_" + String(repeating: "b", count: 40) }
        #expect(await authors.author(for: "shilokuma-inc") == GitAuthor(name: "someone", email: "99+someone@users.noreply.github.com"))
        #expect(transport.requests.count == 2)
    }

    @Test func fallsBackWithoutRememberingWhenAccountIsUnknown() async {
        // 1 回目は 401、2 回目はつながらない（どちらも覚えないので、毎回聞き直す）
        let transport = StubTransport([.json(401, "{}")])
        let logs = OSAllocatedUnfairLock<[String]>(initialState: [])
        let authors = authors(transport, logs: logs)
        #expect(await authors.author(for: "shilokuma-inc") == .fallback)
        #expect(await authors.author(for: "shilokuma-inc") == .fallback)
        // トークンが無い持ち主は、GitHub に聞かない
        #expect(await authors.author(for: "someone-else") == .fallback)
        #expect(transport.requests.count == 2)
        #expect(logs.withLock { $0.count } == 3)
        #expect(logs.withLock { $0.allSatisfy { !$0.contains(Self.token) } })
    }

    @Test func rejectsUnexpectedAccountShape() async {
        for body in [#"{"id":0,"login":"mrs1669"}"#, #"{"id":1,"login":"a@b"}"#, #"{"id":1,"login":""}"#, #"{"login":"mrs1669"}"#] {
            let transport = StubTransport([.json(200, body)])
            #expect(await authors(transport).author(for: "shilokuma-inc") == .fallback, "\(body)")
        }
    }

    @Test func usesLoginWhenProfileHasNoUsableName() {
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: nil).name == "mrs1669")
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: "  ").name == "mrs1669")
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: "<>").name == "mrs1669")
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: "Takumi\n<Muraishi>").name == "TakumiMuraishi")
        // git が名前として受け付けない形（区切りの記号と空白だけ）なら login
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: "...").name == "mrs1669")
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: " ;, '\\").name == "mrs1669")
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: "T. Muraishi").name == "T. Muraishi")
        #expect(GitAuthor.account(id: 1, login: "mrs1669", name: "村石 拓海").name == "村石 拓海")
    }

    @Test func fixedAuthorDefaultsToAskHub() async {
        #expect(await FixedCommitAuthor().author(for: "shilokuma-inc") == GitAuthor(name: "AskHub", email: "worker@askhub.invalid"))
    }
}
