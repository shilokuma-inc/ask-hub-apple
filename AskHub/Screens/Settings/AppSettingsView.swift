import SwiftUI

/// 設定。いまはスワイプの持ち手とデモの場面だけ。トークン・端末の鍵・通知は、つなぎ込みのときに足す
struct AppSettingsView: View {
    @AppStorage(SwipePreferences.handKey) private var hand: Handedness = .right
    @AppStorage(DemoScenario.preferenceKey) private var scenario: DemoScenario = .standard
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
                        ? "推奨はいつも ↗。2 択は ↗↙、3 択は ↗↖↙、4 択は ↗↖↙↘ に割り当てます"
                        : "推奨はいつも ↖。2 択は ↖↘、3 択は ↖↗↘、4 択は ↖↗↘↙ に割り当てます")
                }
                Section {
                    Picker("デモの場面", selection: $scenario) {
                        ForEach(DemoScenario.allCases, id: \.self) { scenario in
                            Text(scenario.label).tag(scenario)
                        }
                    }
                } header: {
                    Text("データ")
                } footer: {
                    Text("試作のため、いまはデモのデータで動いています。GitHub には接続しません")
                }
                Section("あとで作るもの") {
                    Label("GitHub のトークン", systemImage: "key")
                    Label("この端末の鍵と、ほかの端末の承認", systemImage: "lock.shield")
                    Label("通知（急ぎはすぐ、ほかはまとめて）", systemImage: "bell")
                }
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
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
        }
    }
}
