@testable import AskHub
import AskHubProtocol
import Foundation
import Testing

/// ゴールの「別のリポジトリへの依頼の案」の出し方
extension StateClientServiceTests {
    /// 依頼の案を、リポジトリの名前・題・本文ごとに出す。対象のリポジトリの id（小文字）で引ける
    @Test
    func goalShowsOutsideRequests() async throws {
        var files = Self.askingEpic(stage: "awaitingStart")
        files["repos/\(Self.repo)/epics/\(Self.epicID)/goal.json"] = """
        {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
         "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"pending"}],"humanTasks":[],
         "outsideRequests":[{"repo":"Demo-Studio/Ranking-Android","title":"仕様に足す","body":"SPEC.md に書く"}]}
        """
        let goal = try #require(try await makeService(files: files).service.fetchSnapshot().epic(Self.epicID)?.goal)
        let request = Goal.OutsideRequest(repositoryFullName: "Demo-Studio/Ranking-Android", title: "仕様に足す", body: "SPEC.md に書く")
        #expect(goal.outsideRequests == [request])
        #expect(goal.outsideRequests.first?.repositoryID == "demo-studio/ranking-android")
    }

    /// 依頼の案の無いゴールは、空で出す
    @Test
    func goalWithoutOutsideRequestsShowsNone() async throws {
        var files = Self.askingEpic(stage: "awaitingStart")
        files["repos/\(Self.repo)/epics/\(Self.epicID)/goal.json"] = """
        {"v":1,"version":1,"summary":"ランキングを日ごとに入れ替える","decided":[],"outOfScope":[],"doneWhen":["毎日入れ替わる"],
         "tasks":[{"id":"t1","title":"集計を作る","dependsOn":[],"state":"pending"}],"humanTasks":[]}
        """
        let goal = try #require(try await makeService(files: files).service.fetchSnapshot().epic(Self.epicID)?.goal)
        #expect(goal.outsideRequests.isEmpty)
    }
}
