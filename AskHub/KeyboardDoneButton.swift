import SwiftUI

extension View {
    /// キーボードの上に「完了」ボタンを出し、押すと入力欄のフォーカスを外してキーボードを閉じる（Discussion #175）。
    /// 同じ画面で重複して出ないよう、入力欄ごとではなく `Form`（画面）に 1 回だけ付ける。
    /// 次のときは `onlyWhileFocused` にし、フォーカスが付いてから足す（フォーカスのある View の分だけ出る）。
    /// - 付ける View が同じ画面に並ぶとき（デッキに重ねたカード）
    /// - 開いてすぐ `onAppear` でフォーカスを当てるとき（最初から付けておくと「完了」が出ない。iOS 26.5）
    ///
    /// macOS にはソフトウェアキーボードが無いので何も出ない
    func keyboardDoneButton(_ isFocused: FocusState<Bool>.Binding, onlyWhileFocused: Bool = false) -> some View {
        toolbar {
            if !onlyWhileFocused || isFocused.wrappedValue {
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
}
