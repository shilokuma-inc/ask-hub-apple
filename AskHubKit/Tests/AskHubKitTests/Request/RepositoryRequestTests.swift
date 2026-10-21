@testable import AskHubKit
import Foundation
import Testing

struct RepositoryRequestTests {
    private static let create = RepositoryRequest.create(NewRepository(
        repository: "shilokuma-inc/my-quiz-ios",
        template: .quiz,
        appName: "MyQuiz",
        bundleIdentifier: "jp.shilokuma.MyQuiz"
    ))

    /// 標準のテンプレートで作る依頼の目印。`fields` に appName などを足す
    private static func createMarker(_ fields: String) -> String {
        #"<!-- ask-hub:repo-request {"action":"create","repository":"o/r","template":"shilokuma-inc/template-app-ios","#
            + fields + " } -->"
    }

    @Test func roundTripsCreateRequestThroughIssueBody() {
        let body = Self.create.body

        #expect(body.hasPrefix("<!-- ask-hub:repo-request {"))
        #expect(body.contains("| プラットフォーム | iOS |\n| テンプレート | クイズ（shilokuma-inc/template-quiz-app-ios） |"))
        #expect(body.contains(#""platform":"ios""#))
        // 既定は public
        #expect(body.contains(#""private":false"#))
        #expect(body.contains("| 公開範囲 | public |"))
        #expect(RepositoryRequest.parse(body) == Self.create)
        #expect(Self.create.title == "【新規アプリ】shilokuma-inc/my-quiz-ios")
    }

    @Test func roundTripsRemoveRequestThroughIssueBody() {
        let request = RepositoryRequest.remove(RepositoryRemoval(
            repository: "shilokuma-inc/notti-ios",
            deletesLocalFiles: true,
            force: true
        ))

        #expect(RepositoryRequest.parse(request.body) == request)
        #expect(request.title == "【担当の解除】shilokuma-inc/notti-ios")
    }

    @Test func fillsDefaultsForOmittedKeys() {
        let body = #"<!-- ask-hub:repo-request {"action":"create","repository":"o/r","#
            + #""template":"Shilokuma-Inc/Template-App-iOS","appName":"Foo"} -->"#
        #expect(RepositoryRequest.parse(body) == .create(NewRepository(
            repository: "o/r",
            template: .standard,
            appName: "Foo",
            bundleIdentifier: "jp.shilokuma.Foo",
            clonesToOrchestrator: true,
            isPrivate: false
        )))

        let remove = #"<!-- ask-hub:repo-request {"action":"remove","repository":"o/r"} -->"#
        #expect(RepositoryRequest.parse(remove) == .remove(RepositoryRemoval(repository: "o/r", deletesLocalFiles: false)))
    }

    @Test func rejectsMalformedOrUnsafeRequests() {
        let bodies = [
            // 目印が先頭に無い
            "依頼です\n" + Self.create.body,
            // 別の語
            #"<!-- ask-hub:repo-requests {"action":"remove","repository":"o/r"} -->"#,
            // 未知の action
            #"<!-- ask-hub:repo-request {"action":"delete","repository":"o/r"} -->"#,
            // 許可していないテンプレート
            #"<!-- ask-hub:repo-request {"action":"create","repository":"o/r","template":"evil/template","appName":"Foo"} -->"#,
            // シェルに渡す値に使えない文字
            #"<!-- ask-hub:repo-request {"action":"remove","repository":"o/r;rm -rf ~"} -->"#,
            #"<!-- ask-hub:repo-request {"action":"remove","repository":"../r"} -->"#,
            Self.createMarker(#""appName":"1Foo""#),
            Self.createMarker(#""appName":"Foo","bundleIdentifier":"jp..Foo""#),
            // JSON として読めない
            "<!-- ask-hub:repo-request {action} -->"
        ]
        for body in bodies {
            #expect(RepositoryRequest.parse(body) == nil, "\(body)")
        }
    }

    @Test func escapesClosingMarkerInsideValues() {
        // 値に `-->` があっても目印が途中で閉じない（appName の検証で弾かれるが、目印の書き出しは崩さない）
        let request = RepositoryRequest.create(NewRepository(
            repository: "o/r",
            template: .standard,
            appName: "Foo-->",
            bundleIdentifier: "jp.shilokuma.Foo"
        ))
        #expect(request.marker.contains(#""appName":"Foo--\u003e""#))
        #expect(request.marker.hasSuffix(" -->"))
        #expect(!request.isValid)
    }

    @Test func validatesNamesAndIdentifiers() {
        #expect(NewRepository.isValidAppName("MyApp2"))
        #expect(!NewRepository.isValidAppName(""))
        #expect(!NewRepository.isValidAppName("My App"))
        #expect(!NewRepository.isValidAppName("アプリ"))
        #expect(NewRepository.isValidBundleIdentifier("jp.shilokuma.my-app"))
        #expect(!NewRepository.isValidBundleIdentifier("jp"))
        #expect(!NewRepository.isValidBundleIdentifier("jp.shilokuma."))
        #expect(RepositoryName.isValidFullName("shilokuma-inc/my_app.ios"))
        #expect(!RepositoryName.isValidFullName("shilokuma-inc/-app"))
        #expect(!RepositoryName.isValidFullName("o/r/x"))
    }

    @Test func roundTripsPrivateCreateRequest() {
        let request = RepositoryRequest.create(NewRepository(
            repository: "shilokuma-inc/secret-ios",
            template: .standard,
            appName: "Secret",
            bundleIdentifier: "jp.shilokuma.Secret",
            isPrivate: true
        ))
        #expect(request.body.contains(#""private":true"#))
        #expect(RepositoryRequest.parse(request.body) == request)
    }

    @Test func roundTripsVisionOSCreateRequest() {
        let request = RepositoryRequest.create(NewRepository(
            repository: "shilokuma-vision/my-app-visionos",
            template: .visionOSStandard,
            appName: "MyApp",
            bundleIdentifier: "jp.shilokuma.MyApp"
        ))
        let body = request.body

        #expect(body.contains(#""platform":"visionos""#))
        #expect(body.contains(#""template":"shilokuma-vision/template-app-visionos""#))
        #expect(body.contains("| プラットフォーム | visionOS |\n| テンプレート | 通常（shilokuma-vision/template-app-visionos） |"))
        #expect(RepositoryRequest.parse(body) == request)
    }

    @Test func readsMarkersWithoutPlatformAsTemplatePlatform() {
        // プラットフォームを書く前のアプリが書いた目印
        let quiz = #"<!-- ask-hub:repo-request {"action":"create","appName":"MyQuiz","bundleIdentifier":"jp.shilokuma.MyQuiz","#
            + #""clone":true,"private":false,"repository":"shilokuma-inc/my-quiz-ios","#
            + #""template":"shilokuma-inc/template-quiz-app-ios"} -->"#
        #expect(RepositoryRequest.parse(quiz) == Self.create)

        let standard = Self.createMarker(#""appName":"Foo""#)
        guard case let .create(request) = RepositoryRequest.parse(standard) else {
            Issue.record("読めない: \(standard)")
            return
        }
        #expect(request.template == .standard)
        #expect(request.platform == .iOS)

        let vision = #"<!-- ask-hub:repo-request {"action":"create","repository":"o/r","#
            + #""template":"Shilokuma-Vision/Template-App-VisionOS","appName":"Foo"} -->"#
        guard case let .create(visionRequest) = RepositoryRequest.parse(vision) else {
            Issue.record("読めない: \(vision)")
            return
        }
        #expect(visionRequest.template == .visionOSStandard)
        #expect(visionRequest.platform == .visionOS)
    }

    @Test func rejectsPlatformThatDoesNotMatchTemplate() {
        let bodies = [
            // テンプレートと合わない
            Self.createMarker(#""appName":"Foo","platform":"visionos""#),
            #"<!-- ask-hub:repo-request {"action":"create","repository":"o/r","#
                + #""template":"shilokuma-vision/template-app-visionos","appName":"Foo","platform":"ios"} -->"#,
            // 知らない値
            Self.createMarker(#""appName":"Foo","platform":"macos""#),
            Self.createMarker(#""appName":"Foo","platform":"iOS""#),
            Self.createMarker(#""appName":"Foo","platform":"""#)
        ]
        for body in bodies {
            #expect(RepositoryRequest.parse(body) == nil, "\(body)")
        }
        #expect(RepositoryRequest.parse(Self.createMarker(#""appName":"Foo","platform":"ios""#)) != nil)
        // テンプレート名の大文字・小文字の違いは、platform があっても受け付ける
        let vision = #"<!-- ask-hub:repo-request {"action":"create","repository":"o/r","#
            + #""template":"Shilokuma-Vision/Template-App-VisionOS","appName":"Foo","platform":"visionos"} -->"#
        #expect(RepositoryRequest.parse(vision) != nil)
    }

    @Test func listsTemplatesByPlatform() {
        #expect(NewRepository.Platform.allCases == [.iOS, .visionOS])
        #expect(NewRepository.Platform.iOS.templates == [.standard, .quiz])
        #expect(NewRepository.Platform.visionOS.templates == [.visionOSStandard])
        // どのテンプレートも、いずれかのプラットフォームの一覧に 1 回だけ出る
        #expect(NewRepository.Platform.allCases.flatMap(\.templates).sorted { $0.rawValue < $1.rawValue }
            == NewRepository.Template.allCases.sorted { $0.rawValue < $1.rawValue })
        #expect(NewRepository.Platform.iOS.title == "iOS")
        #expect(NewRepository.Platform.visionOS.title == "visionOS")
        #expect(NewRepository.Platform.iOS.repositoryNameSuffix == "-ios")
        #expect(NewRepository.Platform.visionOS.repositoryNameSuffix == "-visionos")
        #expect(NewRepository.Template.quiz.qualifiedTitle == "iOS のクイズ")
        #expect(NewRepository.Template.visionOSStandard.qualifiedTitle == "visionOS の通常")
    }

    @Test func choosesDefaultOrganizationByPlatform() {
        let choices = ["shilokuma-inc", "Shilokuma-Vision", "mrs1669"]
        #expect(NewRepository.Platform.visionOS.defaultOrganization == "shilokuma-vision")
        #expect(NewRepository.Platform.iOS.defaultOrganization == nil)
        // 候補にあれば候補の表記のまま選ぶ
        #expect(NewRepository.Platform.visionOS.organization(choosingFrom: choices) == "Shilokuma-Vision")
        // 候補に無い・既定の無いプラットフォームは先頭
        #expect(NewRepository.Platform.visionOS.organization(choosingFrom: ["shilokuma-inc", "mrs1669"]) == "shilokuma-inc")
        #expect(NewRepository.Platform.iOS.organization(choosingFrom: choices) == "shilokuma-inc")
        #expect(NewRepository.Platform.visionOS.organization(choosingFrom: []) == nil)
    }
}
