@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// 「担当に入れる」の依頼（`repo-request` の `add`。Discussion #722）
@MainActor
struct IdeaRequestModelAddRepositoryTests {
    private static let request = RepositoryRequest.add(RepositoryAddition(repository: "shilokuma-inc/notti-ios"))

    @Test func tellsWhetherRepositoryHasAssignedPC() async {
        let model = IdeaRequestModel.sample()
        await model.loadRepositories()

        #expect(model.hasAssignedPC("shilokuma-inc/ask-hub-apple", now: Date()))
        #expect(!model.hasAssignedPC("shilokuma-inc/notti-ios", now: Date()))
        // 担当の印が古くなれば、担当 PC なしとして扱う
        #expect(!model.hasAssignedPC("shilokuma-inc/ask-hub-apple", now: Date().addingTimeInterval(OrchestratorHeartbeat.freshness + 60)))
        // 一覧に無いリポジトリは担当 PC なし
        #expect(!model.hasAssignedPC("shilokuma-inc/unknown", now: Date()))
    }

    @Test func sendsAddRequestToHubInDemoMode() async {
        let model = IdeaRequestModel.sample()
        await model.loadRepositories()

        let sent = await model.send(Self.request, to: "shilokuma-inc/ask-hub-apple")

        #expect(sent?.request == Self.request)
        #expect(sent?.repository == "shilokuma-inc/ask-hub-apple")
        #expect(sent?.message == "notti-ios を担当に入れる依頼をしました")
        #expect(sent?.linkTitle == "ask-hub-apple#43 を GitHub で開く")
        #expect(model.sentRepositoryRequests.count == 1)
        #expect(model.repositoryRequestError == nil)
    }

    @Test func refusesAddRequestWithoutRepositoryOrHub() async {
        let model = IdeaRequestModel.sample()

        #expect(await model.send(.add(RepositoryAddition(repository: "")), to: "shilokuma-inc/ask-hub-apple") == nil)
        #expect(await model.send(Self.request, to: "") == nil)

        #expect(model.sentRepositoryRequests.isEmpty)
        #expect(model.repositoryRequestError == "依頼先を選び、各項目を正しい形式で入力してください")
    }
}
