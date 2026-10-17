import AskHubKit
import Foundation

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
            codeRabbit: .completed,
            // 最新の head を TestFlight に上げ終わっている
            uploadStatus: .run(sampleUploadRun(id: 501, branch: "epic/mvp", headSHA: "0000000", conclusion: .success))
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
            // 無料枠の上限に当たった PR（"Review rate limited"）。第三者レビューの要修正を直している最中
            codeRabbit: .rateLimited,
            // 上げている最中（CI も実行中なので、終わってももう一度は押せない）
            uploadStatus: .run(sampleUploadRun(
                id: 801,
                repository: "shilokuma-inc/notti-ios",
                branch: "epic/notification",
                headSHA: "0000001",
                status: .inProgress,
                conclusion: nil
            )),
            thirdPartyReview: ThirdPartyReviewMarker(sha: "0000001", must: 2, may: 1),
            finalReview: FinalReviewMarker(state: .fixing, sha: "0000001", attempts: 1)
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
            codeRabbit: .completed,
            // 前のコミット（1111111）で失敗している（PR の最新の head と SHA が違う）。CI は成功しているので上げ直せる
            uploadStatus: .run(sampleUploadRun(id: 1_201, branch: "epic/html-rendering", headSHA: "1111111", conclusion: .failure)),
            // 第三者レビューを待っている間に CodeRabbit がレビューした
            finalReview: FinalReviewMarker(state: .doneCodeRabbit, sha: "0000002")
        ),
        // GitHub Actions は成功・CodeRabbit は処理中。今の head のレビューが済むまでマージできない（Discussion #503）
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
            codeRabbit: .inProgress,
            // まだ TestFlight に上げていない
            uploadStatus: .noRuns,
            // head が変わってから 10 分は CodeRabbit を待つ
            finalReview: FinalReviewMarker(state: .waiting, sha: "0000003")
        ),
        // CodeRabbit がスキップしたので第三者レビューをした。要修正が 0 件なのでマージできる（Discussion #503）
        EpicPullRequest(
            id: "PR_140",
            repository: "shilokuma-inc/ask-hub-apple",
            number: 140,
            title: "【FEAT】epic/final-review を develop に取り込む",
            body: "### 回答待ちの PR\n- なし",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/pull/140")!,
            baseBranch: "develop",
            headBranch: "epic/final-review",
            headSHA: "0000004",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable,
            codeRabbit: .skipped,
            uploadStatus: .noRuns,
            thirdPartyReview: ThirdPartyReviewMarker(sha: "0000004", must: 0, may: 3),
            finalReview: FinalReviewMarker(state: .done, sha: "0000004")
        ),
        // 要修正が 3 回続けて収まらず、第三者レビューがあきらめた。アプリからはマージできない（Q1）
        EpicPullRequest(
            id: "PR_150",
            repository: "shilokuma-inc/notti-ios",
            number: 150,
            title: "【FEAT】epic/sync を develop に取り込む",
            body: "### 回答待ちの PR\n- なし",
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/pull/150")!,
            baseBranch: "develop",
            headBranch: "epic/sync",
            headSHA: "0000005",
            author: "mrs1669",
            checks: .success,
            mergeability: .mergeable,
            codeRabbit: .rateLimited,
            uploadStatus: .noRuns,
            thirdPartyReview: ThirdPartyReviewMarker(sha: "0000005", must: 1, may: 0),
            finalReview: FinalReviewMarker(state: .gaveUp, sha: "0000005", attempts: 3)
        )
    ]

    /// サンプルの Upload ワークフローの run。開始時刻は固定（スクリーンショットで変わらないように）
    private static func sampleUploadRun(
        id: Int,
        repository: String = "shilokuma-inc/ask-hub-apple",
        branch: String,
        headSHA: String,
        status: UploadWorkflowRun.Status = .completed,
        conclusion: UploadWorkflowRun.Conclusion?
    ) -> UploadWorkflowRun {
        UploadWorkflowRun(
            id: id,
            repository: repository,
            branch: branch,
            headSHA: headSHA,
            status: status,
            conclusion: conclusion,
            event: "workflow_dispatch",
            startedAt: Date(timeIntervalSince1970: 1_792_054_800),
            url: URL(string: "https://github.com/\(repository)/actions/runs/\(id)")!
        )
    }

    func epicPullRequests(orgs: [String]) async throws -> [EpicPullRequest] {
        Self.pullRequests
    }

    func merge(_ pullRequest: EpicPullRequest) async throws {}
}
