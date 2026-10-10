@testable import AskHubKit
import Foundation
import Testing

struct DecisionInstructionTests {
    private static let item = DecisionLogItem.parse(line: "- [ ] #319 表の区切り → 採用: カンマ区切り（別案: タブ区切り / 空白区切り）")!
    private static let malformed = DecisionLogItem.parse(line: "- [ ] 番号の無い判断 → 採用: 青")!

    @Test func buildsAlternativeInstruction() {
        #expect(DecisionInstruction.alternative(1, note: "").body(for: Self.item) == "#319 の「表の区切り」は別案 1（タブ区切り）で")
        #expect(DecisionInstruction.alternative(2, note: "  ヘッダー行も同じにする。\n").body(for: Self.item)
            == "#319 の「表の区切り」は別案 2（空白区切り）で\nヘッダー行も同じにする。")
    }

    @Test func keepsLoopReadableInstruction() {
        // ループは playbook の B-0 で `#<PR番号> … 別案 N で` を読むので、PR 番号と「別案 N」を必ず含める
        let body = DecisionInstruction.alternative(1, note: "").body(for: Self.item)
        #expect(body?.hasPrefix("#319 ") == true)
        #expect(body?.contains("別案 1") == true)
    }

    @Test func rejectsAlternativeOutOfRangeOrForMalformedItem() {
        #expect(DecisionInstruction.alternative(0, note: "").body(for: Self.item) == nil)
        #expect(DecisionInstruction.alternative(3, note: "").body(for: Self.item) == nil)
        #expect(DecisionInstruction.alternative(1, note: "").body(for: Self.malformed) == nil)
    }

    @Test func buildsFreeTextInstruction() {
        #expect(DecisionInstruction.freeText("セミコロン区切りにする").body(for: Self.item) == "#319 の「表の区切り」について:\nセミコロン区切りにする")
        // 形式に合わない項目は、チェックを除いた行を引用する
        #expect(DecisionInstruction.freeText("赤にする").body(for: Self.malformed) == "> 番号の無い判断 → 採用: 青\n赤にする")
    }

    @Test func rejectsEmptyFreeText() {
        #expect(DecisionInstruction.freeText("").body(for: Self.item) == nil)
        #expect(DecisionInstruction.freeText(" \n ").body(for: Self.malformed) == nil)
    }

    @Test func rejectsNotesContainingMarkers() {
        for marker in DecisionLogMarker.all {
            #expect(DecisionInstruction.freeText("\(marker) 対応しました").body(for: Self.item) == nil)
            #expect(DecisionInstruction.alternative(1, note: "補足 \(marker)").body(for: Self.item) == nil)
        }
    }
}

struct GitHubDecisionInstructionPosterTests {
    private static let item = DecisionLogItem.parse(line: "- [ ] #319 表の区切り → 採用: カンマ区切り（別案: タブ区切り）")!

    private func makePoster(_ http: MockHTTPClient) -> GitHubDecisionInstructionPoster {
        GitHubDecisionInstructionPoster(client: GitHubClient(token: "github_pat_secret", http: http, sleep: { _ in }))
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

    @Test func postsOneCommentPerInstruction() async throws {
        let url = "https://github.com/shilokuma-inc/ask-hub-apple/issues/355#issuecomment-1"
        let http = MockHTTPClient([.init(status: 201, body: #"{ "id": 1, "html_url": "\#(url)" }"#)])
        let posted = try await makePoster(http).post(.alternative(1, note: ""), for: Self.item, to: Self.issue())

        #expect(posted == URL(string: url))
        #expect(http.requests.map { "\($0.httpMethod ?? "") \($0.url?.path() ?? "")" } == [
            "POST /repos/shilokuma-inc/ask-hub-apple/issues/355/comments"
        ])
        let data = try #require(http.requests.first?.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: String])
        #expect(body == ["body": "#319 の「表の区切り」は別案 1（タブ区切り）で"])
    }

    @Test func refusesInvalidInstructionOrOtherIssues() async {
        let http = MockHTTPClient([])
        await #expect(throws: DecisionInstructionError.invalidInstruction) {
            try await makePoster(http).post(.freeText(""), for: Self.item, to: Self.issue())
        }
        await #expect(throws: DecisionInstructionError.notDecisionLog) {
            try await makePoster(http).post(.alternative(1, note: ""), for: Self.item, to: Self.issue(.needsVerify))
        }
        #expect(http.requests.isEmpty)
    }

    @Test func reportsMissingPermission() async {
        let message = "Resource not accessible by personal access token"
        let http = MockHTTPClient([.init(status: 403, body: #"{ "message": "\#(message)" }"#)])
        await #expect(throws: GitHubError.http(status: 403, message: message)) {
            try await makePoster(http).post(.alternative(1, note: ""), for: Self.item, to: Self.issue())
        }
    }
}
