import Foundation
@testable import OrchestratorKit
import Testing

// MARK: - 最終 PR の材料の取得

extension GitHubOrchestratorTests {
    @Test func collectsEpicMaterialsFromPullRequestsAndIssues() async throws {
        let http = StubHTTPClient([
            #"""
            [
              { "number": 335, "title": "目印を書く", "state": "closed", "merged_at": "2026-10-09T10:00:00Z" },
              { "number": 333, "title": "目印を定める", "state": "closed", "merged_at": "2026-10-09T09:00:00Z" },
              { "number": 334, "title": "閉じただけ", "state": "closed", "merged_at": null },
              { "number": 340, "title": "回答待ち", "state": "open", "merged_at": null }
            ]
            """#,
            #"""
            [
              { "number": 336, "title": "【CHORE】epic/verify-tab-ui の仮決め一覧", "body": "" },
              { "number": 300, "title": "【CHORE】epic/other の仮決め一覧", "body": "" }
            ]
            """#,
            #"""
            [
              { "number": 347, "title": "【CHORE】実機確認: 閉じる", "body": "epic: epic/verify-tab-ui の #346" },
              { "number": 348, "title": "PR", "body": "epic/verify-tab-ui", "pull_request": {} }
            ]
            """#
        ])

        let materials = try await makeGitHub(http).epicMaterials(in: "o/r", branch: "epic/verify-tab-ui")

        // マージされた子 PR は番号順、閉じただけの PR は含めない。PR として返る Issue も除く
        #expect(materials.mergedPullRequests.map(\.number) == [333, 335])
        #expect(materials.openPullRequests.map(\.number) == [340])
        #expect(materials.decisionLogs.map(\.number) == [336])
        #expect(materials.verifyIssues.map(\.number) == [347])
        #expect(http.requests.first?.url?.query?.contains("base=epic/verify-tab-ui") == true)
    }
}
