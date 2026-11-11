import SwiftUI

/// 判断のカードを 1 枚、大きな Before / After で見て答える
struct DecisionSheet: View {
    let epicID: Epic.ID
    let decision: DecisionCard
    /// シートを開いたときの最終 PR の head（答えをこれに結びつける。開いた後に head が進んでいれば、送る前に断られる）
    let headCommit: String?
    /// 答えられる段階か（最終 PR を機械が確かめている・直している間は、見るだけ）
    var canAnswer = true

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var textRequest: TextRequest?
    @State private var sending = SheetSendState()
    /// 最後に送ろうとした答え（失敗したとき、もう一度送る）
    @State private var lastIntent: HumanIntent?

    private var target: IntentTarget {
        .decision(epicID: epicID, decisionID: decision.id)
    }

    var body: some View {
        NavigationStack {
            List {
                if sending.showsStatus {
                    CardSection {
                        SheetSendStatus(state: sending) {
                            if let lastIntent {
                                send(lastIntent)
                            }
                        }
                    }
                } else if store.needsAttention([target]) {
                    // 前に送った答えを司令塔がしばらく受け取っていないか、断った
                    CardSection {
                        ReflectionStatusView(target)
                    }
                }
                DecisionDetailSections(decision: decision)
                if canAnswer, decision.needsReview {
                    CardSection("答える") {
                        Button("OK", systemImage: "checkmark") {
                            send(.respondToDecision(epicID: epicID, decisionID: decision.id, headCommit: headCommit, reply: .accept))
                        }
                        ForEach(decision.alternatives, id: \.self) { alternative in
                            Button("別案にする: \(alternative)", systemImage: "arrow.triangle.branch") {
                                send(.respondToDecision(
                                    epicID: epicID,
                                    decisionID: decision.id,
                                    headCommit: headCommit,
                                    reply: .alternative(alternative)
                                ))
                            }
                        }
                        Button("直してほしい…", systemImage: "pencil") {
                            textRequest = TextRequest(
                                title: "直してほしい",
                                prompt: "どう直してほしいか",
                                purpose: .decisionFix(epicID: epicID, decisionID: decision.id, headCommit: headCommit)
                            )
                        }
                    }
                    .disabled(store.isReflecting([target]))
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle("判断の確認")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                        .disabled(sending.isSending)
                }
            }
            .sheet(item: $textRequest) { request in
                TextRequestSheet(request: request) { text in
                    textRequest = nil
                    send(request.intent(text: text))
                } onCancel: {
                    textRequest = nil
                }
            }
        }
        .sheetSending(sending)
        .sheetSize(.page)
    }

    /// 送る。送り始めたら（同じ答えを送ってあったときも）すぐ閉じ、判断は答えた形になる。送れなければ理由を出して残る
    private func send(_ intent: HumanIntent) {
        lastIntent = intent
        if sending.submit(intent, in: store) {
            dismiss()
        }
    }
}

/// 実機で確かめてほしいこと。マージは止めない
struct VerificationSection: View {
    let epic: Epic
    let items: [VerificationItem]

    var body: some View {
        CardSection {
            if items.contains(where: \.isReady) {
                NavigationLink(value: AppRoute.deck(.verifications(epic.id))) {
                    Label("カードで確かめる", systemImage: "rectangle.stack")
                }
            }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Label(item.text, systemImage: symbol(for: item.state))
                    Text(status(for: item.state))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("実機で確かめてほしいこと · \(items.count)")
        } footer: {
            Text("マージは止めません。TestFlight に上がった後に確かめます")
        }
    }

    private func symbol(for state: VerificationItem.State) -> String {
        switch state {
        case .waitingForBuild: "clock"
        case .ready: "iphone"
        case .confirmed: "checkmark.circle.fill"
        case .problem: "exclamationmark.bubble.fill"
        }
    }

    private func status(for state: VerificationItem.State) -> String {
        switch state {
        case .waitingForBuild: "TestFlight に上がるのを待っています"
        case .ready(let build): "TestFlight \(build) で確かめられます"
        case .confirmed: "確認しました"
        case .problem(let note): "問題あり: \(note)"
        }
    }
}
