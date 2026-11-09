import Observation
import SwiftUI

/// シートの中から送るときの状態。送っている間はシートを触れなくし、失敗したらシートを閉じずに理由を出す
@Observable
final class SheetSendState {
    private(set) var isSending = false
    private(set) var failure: String?

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

extension View {
    /// 送っている間は、シートを下へ払って閉じられないようにする
    func sheetSending(_ state: SheetSendState) -> some View {
        interactiveDismissDisabled(state.isSending)
    }
}
