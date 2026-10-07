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
        #expect(body.contains("| テンプレート | クイズ（shilokuma-inc/template-quiz-app-ios） |"))
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
            clonesToOrchestrator: true
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
}
