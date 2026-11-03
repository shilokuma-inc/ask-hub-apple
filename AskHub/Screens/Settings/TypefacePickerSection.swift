#if DEBUG
import SwiftUI

/// 書体を切り替えて見え方を比べる（デバッグのビルドだけ。ユーザーの要望。2026-11-03）。
/// 選ぶと画面全体がその書体になる。各行はその書体で書いてあるので、ここだけでも見比べられる
struct TypefacePickerSection: View {
    @AppStorage(AppTypeface.preferenceKey) private var selection: AppTypeface = .system

    var body: some View {
        Section {
            Picker("書体", selection: $selection) {
                ForEach(AppTypeface.allCases) { typeface in
                    row(typeface).tag(typeface)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("書体（デバッグ）")
        } footer: {
            Text("「未同梱」の書体は、AskHub/DebugFonts/ にフォントのファイルがありません。選んでもシステムの書体で出ます")
        }
    }

    private func row(_ typeface: AppTypeface) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(typeface.label)
                .font(typeface.font(.body, weight: .semibold))
            Text(typeface.isAvailable ? "\(typeface.summary)・あなたの番 推奨 PR #128 3/5" : "未同梱")
                .font(typeface.font(.footnote))
                .foregroundStyle(.secondary)
        }
    }
}
#endif
