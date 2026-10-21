@testable import AskHub
import AskHubKit
import Foundation
import Testing

/// 「新しいアプリ」のプラットフォームごとの既定値と、送った依頼の表示
@MainActor
struct IdeaRequestModelNewAppTests {
    private func makeModel(organizations: [String]) -> IdeaRequestModel {
        IdeaRequestModel(tokenStore: InMemoryTokenStore(), organizations: { organizations })
    }

    @Test func choosesShilokumaVisionForVisionOSWhenConfigured() {
        let model = makeModel(organizations: ["shilokuma-inc", "shilokuma-vision"])

        #expect(model.defaultOrganization(for: .iOS) == "shilokuma-inc")
        #expect(model.defaultOrganization(for: .visionOS) == "shilokuma-vision")
        #expect(model.missingDefaultOrganization(for: .iOS) == nil)
        #expect(model.missingDefaultOrganization(for: .visionOS) == nil)
    }

    @Test func fallsBackToFirstOrganizationAndExplainsWhenNotConfigured() {
        let model = makeModel(organizations: ["shilokuma-inc"])

        #expect(model.defaultOrganization(for: .visionOS) == "shilokuma-inc")
        #expect(model.missingDefaultOrganization(for: .visionOS) == "shilokuma-vision")
        // 大文字・小文字だけが違うものは、一覧にあるものとして扱う
        let mixedCase = makeModel(organizations: ["Shilokuma-Vision"])
        #expect(mixedCase.defaultOrganization(for: .visionOS) == "Shilokuma-Vision")
        #expect(mixedCase.missingDefaultOrganization(for: .visionOS) == nil)
        // 一覧が空なら選ばない
        #expect(makeModel(organizations: []).defaultOrganization(for: .visionOS) == nil)
    }

    @Test func sentCreateRequestShowsPlatform() {
        let issue = CreatedIssue(number: 9, htmlURL: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/9")!)
        let vision = SentRepositoryRequest(
            request: .create(NewRepository(
                repository: "shilokuma-vision/my-app-visionos",
                template: .visionOSStandard,
                appName: "MyApp",
                bundleIdentifier: "jp.shilokuma.MyApp"
            )),
            repository: "shilokuma-inc/ask-hub-apple",
            issue: issue
        )
        #expect(vision.message == "my-app-visionos（visionOS）の作成を依頼しました")
    }

    @Test func sampleOffersShilokumaVision() {
        #expect(IdeaRequestModel.sample().organizationChoices == ["shilokuma-inc", "shilokuma-vision"])
    }
}
