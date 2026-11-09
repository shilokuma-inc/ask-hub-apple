@testable import AskHub
import Testing

/// 設定に出すバージョンとビルド番号。Info.plist から読み、読めないときは「不明」にする
@MainActor
struct AppVersionInfoTests {
    /// 値があれば、そのまま出す
    @Test
    func readsVersionAndBuild() {
        let info = AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "45"])
        #expect(info.version == "1.2.0")
        #expect(info.build == "45")
    }

    /// 辞書が無ければ、どちらも「不明」
    @Test
    func missingDictionaryIsUnknown() {
        let info = AppVersionInfo(infoDictionary: nil)
        #expect(info.version == AppVersionInfo.unknown)
        #expect(info.build == AppVersionInfo.unknown)
    }

    /// 鍵が無い・文字列でない・空なら「不明」
    @Test
    func missingOrInvalidValuesAreUnknown() {
        #expect(AppVersionInfo(infoDictionary: [:]).version == "不明")
        #expect(AppVersionInfo(infoDictionary: ["CFBundleVersion": 45]).build == "不明")
        #expect(AppVersionInfo(infoDictionary: ["CFBundleShortVersionString": " "]).version == "不明")
    }

    /// 片方だけ読めても、もう片方は出す
    @Test
    func readsOneWhenTheOtherIsMissing() {
        let info = AppVersionInfo(infoDictionary: ["CFBundleVersion": "45"])
        #expect(info.version == "不明")
        #expect(info.build == "45")
    }

    /// テストを動かしているアプリの Info.plist からは、両方とも読める
    @Test
    func mainBundleHasValues() {
        let info = AppVersionInfo()
        #expect(info.version != AppVersionInfo.unknown)
        #expect(info.build != AppVersionInfo.unknown)
    }
}
