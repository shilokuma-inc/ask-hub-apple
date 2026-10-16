import AskHubKit
import Foundation

extension MergeQueueModel {
    /// デモモード・Preview・UI テスト用。GitHub には接続しない
    static func sample() -> MergeQueueModel {
        MergeQueueModel(tokenStore: InMemoryTokenStore(token: "sample")) { _ in SampleMergeQueue() }
    }
}

/// デモモード・Preview・UI テスト用。マージしたことにして GitHub には送らない
struct SampleMergeQueue: MergeQueueProviding {
    static let pullRequests = [
        EpicPullRequest(
            id: "PR_50",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 50,
            title: "【FEAT】epic/mvp を develop に取り込む",
            body: """
                ### 回答待ちの PR
                - なし

                ### 返答のない仮決め（既定値のまま確定）
                - #9 の 20 件

                ### 実機確認 Issue
                - #18 PAT の Keychain への保存
                - #27 ready-for-loop からのループの起動
                """,
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/50")!,
            baseBranch: "develop",
            headBranch: "epic/mvp",
            headSHA: "0000000",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable,
            codeRabbit: .completed
        ),
        EpicPullRequest(
            id: "PR_80",
            repository: "shilokuma-inc/notti-ios",
            number: 80,
            title: "【FEAT】epic/notification を develop に取り込む",
            body: "### 回答待ちの PR\n- #77",
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/pull/80")!,
            baseBranch: "develop",
            headBranch: "epic/notification",
            headSHA: "0000001",
            author: "mrs1669",
            checks: .pending,
            mergeability: .mergeable,
            // 無料枠の上限に当たった PR（"Review rate limited"）。CI が終わればマージできる
            codeRabbit: .rateLimited
        ),
        EpicPullRequest(
            id: "PR_120",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 120,
            title: "【FEAT】epic/html-rendering を develop に取り込む",
            // HTML タグと Markdown が混ざった本文（表示の確認用）
            body: """
                <h3>回答待ちの PR</h3>
                <ul>
                <li>なし</li>
                </ul>
                <h3>返答のない仮決め（既定値のまま確定）</h3>
                <p>#161 の 6 件。<b>エンティティのデコード範囲</b>と <code>&lt;br&gt;</code> の変換を含む。詳細は <a href="https://github.com/shilokuma-inc/ask-hub-apple/issues/161">#161</a></p>

                ### 実機確認 Issue
                - なし

                ### 保留にしたタスク
                1. なし
                """,
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/120")!,
            baseBranch: "develop",
            headBranch: "epic/html-rendering",
            headSHA: "0000002",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable,
            codeRabbit: .completed
        ),
        // GitHub Actions は成功・CodeRabbit は処理中。CodeRabbit はマージ条件ではないのでマージできる（Discussion #460）
        EpicPullRequest(
            id: "PR_130",
            repository: "shilokuma-inc/notti-ios",
            number: 130,
            title: "【FEAT】epic/widget を develop に取り込む",
            body: """
                ### 回答待ちの PR
                - なし

                ### 返答のない仮決め（既定値のまま確定）
                - #125 の 3 件

                ### 実機確認 Issue
                - #128 ウィジェットの更新間隔
                """,
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/pull/130")!,
            baseBranch: "develop",
            headBranch: "epic/widget",
            headSHA: "0000003",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable,
            codeRabbit: .inProgress
        )
    ]

    func epicPullRequests(orgs: [String]) async throws -> [EpicPullRequest] {
        Self.pullRequests
    }

    func merge(_ pullRequest: EpicPullRequest) async throws {}
}
