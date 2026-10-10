@testable import AskHubKit
import Foundation
import Testing

struct DecisionLogCheckTests {
    private static let body = """
        チェックを付けたものは承認。

        - [x] #3 色 → 採用: 青
        - [ ] #4 文言 → 採用: 「保存」（別案: 「完了」）
        - [ ] #5 余白 → 採用: 16pt
        """

    @Test func checksOnlyTheMatchingLine() {
        let result = DecisionLogCheck.check("#4 文言 → 採用: 「保存」（別案: 「完了」）", in: Self.body)
        #expect(result == .checked("""
            チェックを付けたものは承認。

            - [x] #3 色 → 採用: 青
            - [x] #4 文言 → 採用: 「保存」（別案: 「完了」）
            - [ ] #5 余白 → 採用: 16pt
            """))
    }

    @Test func keepsIndentationAndLineEndings() {
        let body = "冒頭\r\n  - [ ] #4 文言 → 採用: 保存  \r\n- [ ] #5 余白 → 採用: 16pt\r\n"
        #expect(DecisionLogCheck.check(" #4 文言 → 採用: 保存 ", in: body)
            == .checked("冒頭\r\n  - [x] #4 文言 → 採用: 保存  \r\n- [ ] #5 余白 → 採用: 16pt\r\n"))
    }

    @Test func checksFirstOfDuplicatedLines() {
        let body = "- [ ] #4 文言 → 採用: 保存\n- [ ] #4 文言 → 採用: 保存"
        #expect(DecisionLogCheck.check("#4 文言 → 採用: 保存", in: body) == .checked("- [x] #4 文言 → 採用: 保存\n- [ ] #4 文言 → 採用: 保存"))
    }

    @Test func prefersUncheckedLineOverCheckedDuplicate() {
        let body = "- [x] #4 文言 → 採用: 保存\n- [ ] #4 文言 → 採用: 保存"
        #expect(DecisionLogCheck.check("#4 文言 → 採用: 保存", in: body) == .checked("- [x] #4 文言 → 採用: 保存\n- [x] #4 文言 → 採用: 保存"))
    }

    @Test func reportsAlreadyCheckedLine() {
        #expect(DecisionLogCheck.check("#3 色 → 採用: 青", in: Self.body) == .alreadyChecked)
        #expect(DecisionLogCheck.check("#3 色 → 採用: 青", in: "- [X] #3 色 → 採用: 青") == .alreadyChecked)
    }

    @Test func doesNotMatchChangedOrPartialLines() {
        // ループが ` → 変更: ` を追記した・文言を変えた行は、表示した行と一致しないので書き換えない
        #expect(DecisionLogCheck.check("#5 余白", in: Self.body) == .notFound)
        #expect(DecisionLogCheck.check("#5 余白 → 採用: 16pt", in: "- [ ] #5 余白 → 採用: 16pt → 変更: 8pt") == .notFound)
        #expect(DecisionLogCheck.check("#5 余白 → 採用: 16pt", in: "#5 余白 → 採用: 16pt") == .notFound)
        #expect(DecisionLogCheck.check("#5 余白 → 採用: 16pt", in: "") == .notFound)
    }

    @Test func agreesWithItemParserOnText() {
        // アプリは `DecisionLogItem.text` を渡すので、パーサーと同じ読み方で一致させる
        let body = "説明\n  - [ ] #4 文言 → 採用: 保存  \r\n- [x] #3 色 → 採用: 青\n- [ ] 形式に合わない行\n- [ ]#5 詰めて書いた行 → 採用: 8pt"
        for item in DecisionLogItem.items(in: body) {
            let result = DecisionLogCheck.check(item.text, in: body)
            if item.isChecked {
                #expect(result == .alreadyChecked)
            } else if case let .checked(updated) = result {
                #expect(DecisionLogItem.items(in: updated).first { $0.text == item.text }?.isChecked == true)
            } else {
                Issue.record("\(item.text) にチェックを付けられない")
            }
        }
    }
}

struct GitHubDecisionApproverTests {
    private func makeApprover(_ http: MockHTTPClient) -> GitHubDecisionApprover {
        GitHubDecisionApprover(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
    }

    private static func issue(_ kind: InboxIssue.Kind = .decisionLog) -> InboxIssue {
        InboxIssue(
            id: "I_355",
            kind: kind,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 355,
            title: "【CHORE】epic/in-app-decision-verify の仮決め一覧",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/355")!,
            author: "mrs1669",
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static func json(body: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["number": 355, "body": body])
        return try #require(String(bytes: data, encoding: .utf8))
    }

    @Test func rereadsBodyThenPatchesOnlyTheCheck() async throws {
        // 画面を開いた後にループが行を追記していても、読み直した本文に対して書き換える
        let current = "説明\n- [ ] #4 文言 → 採用: 保存\n- [ ] #6 追記された行 → 採用: 赤"
        let updated = "説明\n- [x] #4 文言 → 採用: 保存\n- [ ] #6 追記された行 → 採用: 赤"
        let http = MockHTTPClient([
            .init(status: 200, body: try Self.json(body: current)),
            .init(status: 200, body: try Self.json(body: updated))
        ])
        let result = try await makeApprover(http).approve("#4 文言 → 採用: 保存", in: Self.issue())

        #expect(result == .approved(body: updated))
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "GET /repos/shilokuma-inc/ask-hub-apple/issues/355",
            "PATCH /repos/shilokuma-inc/ask-hub-apple/issues/355"
        ])
        let data = try #require(http.requests.last?.httpBody)
        let sent = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(sent == ["body": updated])
    }

    @Test func doesNotPatchWhenLineIsMissingOrChecked() async throws {
        let current = "- [x] #3 色 → 採用: 青"
        for (text, expected) in [
            ("#3 色 → 採用: 青", DecisionApproval.alreadyApproved(body: current)),
            ("#4 文言 → 採用: 保存", DecisionApproval.notFound(body: current))
        ] {
            let http = MockHTTPClient([.init(status: 200, body: try Self.json(body: current))])
            #expect(try await makeApprover(http).approve(text, in: Self.issue()) == expected)
            #expect(http.requests.map(\.httpMethod) == ["GET"])
        }
    }

    @Test func treatsMissingBodyAsEmpty() async throws {
        let http = MockHTTPClient([.init(status: 200, body: #"{ "number": 355, "body": null }"#)])
        #expect(try await makeApprover(http).approve("#4 文言 → 採用: 保存", in: Self.issue()) == .notFound(body: ""))
    }

    @Test func refusesToRewriteVerificationIssue() async {
        let http = MockHTTPClient([])
        await #expect(throws: DecisionApprovalError.notDecisionLog) {
            try await makeApprover(http).approve("#4 文言 → 採用: 保存", in: Self.issue(.needsVerify))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func reportsMissingPermission() async throws {
        let message = "Resource not accessible by personal access token"
        let http = MockHTTPClient([
            .init(status: 200, body: try Self.json(body: "- [ ] #4 文言 → 採用: 保存")),
            .init(status: 403, body: #"{ "message": "\#(message)" }"#)
        ])
        await #expect(throws: GitHubError.http(status: 403, message: message)) {
            try await makeApprover(http).approve("#4 文言 → 採用: 保存", in: Self.issue())
        }
    }
}
