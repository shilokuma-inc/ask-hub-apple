import Foundation
import Testing

/// 画面の向き。iPhone は縦だけ、iPad は縦・横の 4 方向。Xcode が作る Info.plist の値を確かめる
#if os(iOS)
@MainActor
struct SupportedOrientationsTests {
    /// テストを動かしているアプリの Info.plist を、端末ごとの鍵（~iphone・~ipad）を残したまま読む
    private func rawInfo() throws -> [String: Any] {
        let data = try Data(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(plist as? [String: Any])
    }

    /// iPhone は縦（上下逆さを除く）だけ
    @Test
    func iPhoneIsPortraitOnly() throws {
        let orientations = try rawInfo()["UISupportedInterfaceOrientations~iphone"] as? [String]
        #expect(orientations == ["UIInterfaceOrientationPortrait"])
    }

    /// iPad は縦・横の 4 方向のまま
    @Test
    func iPadSupportsAllFour() throws {
        let orientations = try rawInfo()["UISupportedInterfaceOrientations~ipad"] as? [String]
        #expect(Set(orientations ?? []) == [
            "UIInterfaceOrientationPortrait",
            "UIInterfaceOrientationPortraitUpsideDown",
            "UIInterfaceOrientationLandscapeLeft",
            "UIInterfaceOrientationLandscapeRight",
        ])
    }
}
#endif
