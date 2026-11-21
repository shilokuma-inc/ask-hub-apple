import SwiftUI

/// アプリの見た目（テーマ）。この端末の UserDefaults だけに保存し、iCloud には送らない
enum AppTheme: String, Hashable, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "システム"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    /// `.preferredColorScheme` に渡す値。システムは nil で、端末の外観の設定に従う
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// アプリ全体にかける値。App Store のスクショの撮影モードでは、保存された値によらずシステムの既定に従う
    func colorScheme(isScreenshotDemo: Bool) -> ColorScheme? {
        isScreenshotDemo ? nil : colorScheme
    }
}

/// テーマの設定
enum ThemePreferences {
    static let themeKey = "appTheme"
}
