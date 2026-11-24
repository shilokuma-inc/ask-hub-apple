@testable import AskHub
import AskHubProtocol
import Testing

/// 新しいアプリの欄に人が入れた値があるか（依頼のシートを閉じる前に確かめるか）
struct NewAppRequestTests {
    /// 開いたばかり（テンプレート・持ち主・公開範囲を選んだだけ）なら、入れた値に数えない
    @Test
    func selectionsAloneAreNotInput() {
        let request = NewAppRequest(template: .visionos, owner: "demo-studio", visibility: .private)
        #expect(!request.hasInput)
    }

    /// リポジトリの名前・アプリ名・Bundle ID のどれかを入れたら、入れた値に数える
    @Test
    func typedFieldsAreInput() {
        #expect(NewAppRequest(name: "memo-widget-ios").hasInput)
        #expect(NewAppRequest(appName: "MemoWidget").hasInput)
        #expect(NewAppRequest(bundleId: "com.example.Memo").hasInput)
    }

    /// リポジトリの名前を消した後に残る Bundle ID の案（`jp.shilokuma.`）は、人が入れた値に数えない
    @Test
    func suggestedBundleIdIsNotInput() {
        let request = NewAppRequest(bundleId: CreateRepositoryIntent.defaultBundleId(appName: ""))
        #expect(!request.hasInput)
    }
}
