@testable import AskHub
import Testing

/// App Store のスクショの表示サイズ（App Asset Library の配置グループ）の呼び名
struct StoreScreenshotDisplayNameTests {
    @Test(arguments: [
        ("IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE", "iPhone 6.9 インチ"),
        ("IPHONE_DYNAMIC_ISLAND_MEDIUM_PROFILE", "iPhone 6.3 インチ"),
        ("IPHONE_DUO_PROFILE", "iPhone Duo"),
        ("IPAD_13_PROFILE", "iPad 13 インチ"),
        ("IPAD_129_PROFILE", "iPad 12.9 インチ"),
        ("MAC_PROFILE", "Mac"),
        // 知らない配置グループは、そのまま出す
        ("FUTURE_DEVICE_PROFILE", "FUTURE_DEVICE_PROFILE")
    ])
    func namesDisplayTypeByItsDisplayClass(displayType: String, name: String) {
        #expect(Submission.ScreenshotSet.displayName(displayType) == name)
    }
}
