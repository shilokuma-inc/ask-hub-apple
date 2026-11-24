import Observation
import SwiftUI

/// シートの中から送るときの状態。送っている間はシートを触れなくし、失敗したらシートを閉じずに理由を出す。
/// 送った結果を先に画面に出せる操作（`submit`）は、送り終えるのを待たずに閉じる
@Observable
final class SheetSendState {
    private(set) var isSending = false
    private(set) var failure: String?

    /// 送り始めて、送り終えるのを待たずに戻る。送り始めたら（送ってあったときも）true を返す（呼び出し元はシートを閉じる。
    /// 送れなかったら帯で知らせて画面を元に戻す）。同じ対象への操作が同期を待っていて送れなければ、理由を `failure` に入れて false
    func submit(_ intent: HumanIntent, in store: ClientStore) -> Bool {
        failure = nil
        if case .blocked(let message) = store.submit(intent) {
            failure = message
            return false
        }
        return true
    }

    /// 送る。失敗は帯ではなく `failure` に入れる（呼び出し元は、置けたらシートを閉じる）
    func send(_ intent: HumanIntent, in store: ClientStore) async -> ClientStore.SendResult {
        isSending = true
        failure = nil
        defer { isSending = false }
        let result = await store.send(intent, reportsFailure: false)
        if case .failed(let message) = result {
            failure = message
        }
        return result
    }
}

/// シートの右上の送るボタン。送っている間は、進み具合を出して押せなくする
struct SheetSendButton: View {
    let title: String
    let isSending: Bool
    let action: () -> Void

    init(_ title: String, isSending: Bool, action: @escaping () -> Void) {
        self.title = title
        self.isSending = isSending
        self.action = action
    }

    var body: some View {
        if isSending {
            ProgressView()
                .accessibilityLabel("送っています")
        } else {
            Button(title, action: action)
        }
    }
}

/// 送っている間と、送れなかった理由。シートの一番上に出す
struct SheetSendStatus: View {
    let state: SheetSendState
    /// 失敗したときに、同じ内容でもう一度送る
    let retry: () -> Void

    var body: some View {
        if state.isSending {
            HStack(spacing: 10) {
                ProgressView()
                Text("送っています…")
                    .foregroundStyle(.secondary)
            }
        } else if let failure = state.failure {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("送れませんでした: \(failure)")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.danger)
                }
                Button("もう一度送る", systemImage: "arrow.clockwise", action: retry)
                    .buttonStyle(.borderless)
            }
        }
    }
}

extension SheetSendState {
    /// シートの一番上に、送っている間か失敗を出すか
    var showsStatus: Bool {
        isSending || failure != nil
    }
}

/// シートの左上のキャンセル。閉じると消える入力があれば、閉じる前に破棄するかを確かめる（何も入れていなければ、すぐ閉じる）
struct SheetCancelButton: View {
    /// 閉じると消える入力があるか
    let hasInput: Bool
    let action: () -> Void
    @State private var isConfirming = false

    var body: some View {
        Button("キャンセル") {
            if hasInput {
                isConfirming = true
            } else {
                action()
            }
        }
        // iOS 26 では押したボタンから出る吹き出しになるので、ボタンに付ける
        .confirmationDialog("入力した内容を破棄しますか？", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("破棄する", role: .destructive, action: action)
            Button("入力を続ける", role: .cancel) {}
        } message: {
            Text("閉じると、入力した内容は残りません")
        }
    }
}

extension View {
    /// 送っている間は、シートを下へ払って閉じられないようにする。
    /// `hasInput` なら、送っていなくても下へ払って閉じさせない（入れた内容が黙って消えないように。閉じるのは `SheetCancelButton` で確かめてから）
    func sheetSending(_ state: SheetSendState, hasInput: Bool = false) -> some View {
        interactiveDismissDisabled(state.isSending || hasInput)
    }
}
