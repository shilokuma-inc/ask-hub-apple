import SwiftUI

/// スクショを撮り直す組（表示サイズ・言語）を選ぶ。すべて選んだら、すべての組を撮り直す（`retakeScreenshots` の空の並び）。
/// 一部だけ撮り直すと、ほかの組は前の結果を引き継ぐ（GitHub Actions で撮るリポジトリだけ。UI テストで撮るリポジトリは、すべて撮り直す）
struct RetakeScreenshotsSheet: View {
    let screenshots: Submission.StoreScreenshots
    /// 選んだ表示サイズ・言語（すべてなら空）で送る
    let onRetake: (_ displayTypes: [String], _ locales: [String]) -> Void
    let onClose: () -> Void
    @State private var displayTypes: Set<String> = []
    @State private var locales: Set<String> = []

    /// 撮った組の表示サイズ（並びは撮った順）
    private var allDisplayTypes: [String] { Self.ordered(screenshots.sets.map(\.displayType)) }
    /// 撮った組の言語（最初が基準の言語）
    private var allLocales: [String] { Self.ordered(screenshots.sets.map(\.locale)) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(allDisplayTypes, id: \.self) { type in
                        Toggle(Submission.ScreenshotSet.displayName(type), isOn: binding(type, in: $displayTypes))
                    }
                } header: {
                    Text("表示サイズ")
                }
                Section {
                    ForEach(allLocales, id: \.self) { locale in
                        Toggle(Submission.Localized(locale: locale, text: "").localeName, isOn: binding(locale, in: $locales))
                    }
                } header: {
                    Text("言語")
                } footer: {
                    Text("今の release ブランチの先頭で撮り直し、前回の App Store のものと比べ直します。選ばなかった組は、前に撮ったものを使います")
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("スクショを撮り直す")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("撮り直す") {
                        let everyType = displayTypes.count == allDisplayTypes.count
                        let everyLocale = locales.count == allLocales.count
                        let types = everyType ? [] : allDisplayTypes.filter(displayTypes.contains)
                        onRetake(types, everyLocale ? [] : allLocales.filter(locales.contains))
                    }
                    .disabled(displayTypes.isEmpty || locales.isEmpty)
                    .accessibilityIdentifier("retake-screenshots-send")
                }
            }
            .onAppear {
                if displayTypes.isEmpty { displayTypes = Set(allDisplayTypes) }
                if locales.isEmpty { locales = Set(allLocales) }
            }
        }
    }

    private func binding(_ value: String, in set: Binding<Set<String>>) -> Binding<Bool> {
        Binding { set.wrappedValue.contains(value) } set: { isOn in
            if isOn { set.wrappedValue.insert(value) } else { set.wrappedValue.remove(value) }
        }
    }

    /// 重なりを除き、最初に出た順に並べる
    static func ordered(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }
}
