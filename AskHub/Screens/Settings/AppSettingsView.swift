import SwiftUI

/// 設定。スワイプの持ち手と、データ（状態リポジトリ・GitHub のトークン・この端末の鍵、またはデモの場面）
struct AppSettingsView: View {
    @AppStorage(SwipePreferences.handKey) private var hand: Handedness = .right
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("スマホを持つ手", selection: $hand) {
                        ForEach(Handedness.allCases, id: \.self) { hand in
                            Text(hand.label).tag(hand)
                        }
                    }
                } header: {
                    Text("スワイプ")
                } footer: {
                    Text(hand == .right
                        ? "推奨はいつも ↗。2 択は ↗↙、3 択は ↗↖↙、4 択は ↗↖↙↘ に割り当てます。自由回答の選択肢は、推奨の対角の ↙ に置きます"
                        : "推奨はいつも ↖。2 択は ↖↘、3 択は ↖↗↘、4 択は ↖↗↘↙ に割り当てます。自由回答の選択肢は、推奨の対角の ↘ に置きます")
                }
                ConnectionSettingsSections()
                Section("あとで作るもの") {
                    Label("通知（急ぎはすぐ、ほかはまとめて）", systemImage: "bell")
                }
                .foregroundStyle(.secondary)
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
        }
    }
}
