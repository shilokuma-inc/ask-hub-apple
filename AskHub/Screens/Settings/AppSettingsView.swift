import SwiftUI

/// 設定。テーマと、スワイプの持ち手（iOS だけ）と、データ（状態リポジトリ・GitHub のトークン・この端末の鍵・通知、またはデモの場面）と、このアプリのバージョン
struct AppSettingsView: View {
    @AppStorage(ThemePreferences.themeKey) private var theme: AppTheme = .system
    @AppStorage(SwipePreferences.handKey) private var hand: Handedness = .right
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                themeSection
                if SwipePreferences.choosesHand {
                    swipeSection
                }
                ConnectionSettingsSections()
                SiriShortcutsSection()
                aboutSection
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("設定")
            #if os(iOS)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            #endif
        }
    }

    /// この端末だけに保存し、アプリ全体（macOS は設定のウィンドウも）にすぐ反映する（AskHub の preferredColorScheme）
    private var themeSection: some View {
        Section {
            Picker("テーマ", selection: $theme) {
                ForEach(AppTheme.allCases, id: \.self) { theme in
                    Text(theme.label).tag(theme)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings.theme")
        } header: {
            Text("テーマ")
        } footer: {
            Text("システムは端末の外観の設定に従います")
        }
    }

    /// スマホを持つ手で、選択肢を置く方向を鏡写しにする（iOS だけ）
    private var swipeSection: some View {
        Section {
            Picker("スマホを持つ手", selection: $hand) {
                ForEach(Handedness.allCases, id: \.self) { hand in
                    Text(hand.label).tag(hand)
                }
            }
        } header: {
            Text("スワイプ")
        } footer: {
            Text(SwipeLayout.summary(hand: hand))
        }
    }

    private var aboutSection: some View {
        let info = AppVersionInfo()
        return Section("このアプリについて") {
            LabeledContent("バージョン", value: info.version)
                .accessibilityIdentifier("settings.version")
            LabeledContent("ビルド", value: info.build)
                .accessibilityIdentifier("settings.build")
        }
    }
}

extension DemoScenario {
    static let preferenceKey = "demoScenario"

    var label: String {
        switch self {
        case .standard: "ひととおり（標準）"
        case .quiet: "人の出番が無い"
        case .failing: "読めない"
        case .partial: "一部だけ読めない"
        case .tooLarge: "大きすぎる依頼がある"
        case .started: "開始した後の段取り"
        case .manyFinished: "終わったものが多い"
        case .rateLimited: "GitHub の上限に当たった"
        }
    }
}
