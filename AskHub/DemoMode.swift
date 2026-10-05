import SwiftUI

/// GitHub のトークンなしで画面と操作を試すデモモード（TestFlight の審査や外部テスター向け）。
///
/// デモモードの間はサンプルデータを表示し、GitHub には接続しない（回答・マージ・依頼は送ったことにするだけ）。
/// オン・オフは秘密ではないので UserDefaults に保存し、アプリを再起動しても続ける
enum DemoMode {
    static let defaultsKey = "AskHubDemoMode"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

extension EnvironmentValues {
    /// デモモードか
    @Entry var isDemoMode = false
    /// デモモードを始める（`true`）・終える（`false`）。App が設定する。Preview などでは `nil`
    @Entry var setDemoMode: (@MainActor (Bool) -> Void)?
}

/// 「サンプルデータで試す」ボタン。デモモードを切り替えられないとき（Preview など）は出さない
struct TryDemoButton: View {
    @Environment(\.setDemoMode)
    private var setDemoMode

    var body: some View {
        if let setDemoMode {
            Button("サンプルデータで試す") { setDemoMode(true) }
        }
    }
}

/// デモモードの間、画面の上に出す帯
struct DemoModeBanner: View {
    @Environment(\.setDemoMode)
    private var setDemoMode

    var body: some View {
        HStack(spacing: 8) {
            Label("デモモード（サンプルデータ）", systemImage: "theatermasks.fill")
                .font(.footnote.weight(.semibold))
            Spacer()
            if let setDemoMode {
                Button("終了") { setDemoMode(false) }
                    .font(.footnote)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.indigo, in: .rect(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }
}

extension View {
    /// デモモードの間、ナビゲーションバーの下に帯を出す（ツールバーのボタンを隠さない）
    func demoModeBanner() -> some View {
        modifier(DemoModeBannerModifier())
    }
}

private struct DemoModeBannerModifier: ViewModifier {
    @Environment(\.isDemoMode)
    private var isDemoMode

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if isDemoMode {
                DemoModeBanner()
            }
        }
    }
}
