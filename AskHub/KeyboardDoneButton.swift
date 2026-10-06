import SwiftUI

extension View {
    /// キーボードの上に「完了」ボタンを出し、押すと入力欄のフォーカスを外してキーボードを閉じる（Discussion #175）。
    /// 同じ画面で重複して出ないよう、入力欄ごとではなく `Form`（画面）に 1 回だけ付ける。
    /// macOS にはソフトウェアキーボードが無いので何も出ない
    func keyboardDoneButton(_ isFocused: FocusState<Bool>.Binding) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完了") {
                    isFocused.wrappedValue = false
                }
                .accessibilityIdentifier("keyboard-done")
            }
        }
    }
}
