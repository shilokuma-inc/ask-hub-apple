@testable import AskHub
import Foundation
import SwiftUI
import Testing

/// テーマの選択肢から ColorScheme への対応と、保存する値の往復
@MainActor
struct AppThemeTests {
    @Test
    func mapsToColorScheme() {
        #expect(AppTheme.system.colorScheme == nil)
        #expect(AppTheme.light.colorScheme == .light)
        #expect(AppTheme.dark.colorScheme == .dark)
    }

    @Test
    func listsSystemLightDarkInOrder() {
        #expect(AppTheme.allCases == [.system, .light, .dark])
        #expect(AppTheme.allCases.map(\.label) == ["システム", "ライト", "ダーク"])
    }

    @Test(arguments: AppTheme.allCases)
    func roundTripsRawValue(theme: AppTheme) {
        #expect(AppTheme(rawValue: theme.rawValue) == theme)
    }

    /// UserDefaults に書いた値を読み直しても同じテーマになる（@AppStorage と同じキーと rawValue で保存する）
    @Test(arguments: AppTheme.allCases)
    func roundTripsThroughUserDefaults(theme: AppTheme) throws {
        let suiteName = "AppThemeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(theme.rawValue, forKey: ThemePreferences.themeKey)
        let stored = defaults.string(forKey: ThemePreferences.themeKey).flatMap(AppTheme.init(rawValue:))
        #expect(stored == theme)
    }

    @Test
    func ignoresUnknownRawValue() {
        #expect(AppTheme(rawValue: "sepia") == nil)
    }

    /// 撮影モードでは、保存された値によらずシステムの既定に従う
    @Test(arguments: AppTheme.allCases)
    func followsSystemInScreenshotDemo(theme: AppTheme) {
        #expect(theme.colorScheme(isScreenshotDemo: true) == nil)
        #expect(theme.colorScheme(isScreenshotDemo: false) == theme.colorScheme)
    }
}
