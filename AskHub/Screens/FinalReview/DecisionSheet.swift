import SwiftUI

/// 判断のカードを 1 枚、大きな Before / After で見て答える
struct DecisionSheet: View {
    let epicID: Epic.ID
    let decision: DecisionCard

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var textRequest: TextRequest?

    var body: some View {
        NavigationStack {
            List {
                DecisionDetailSections(decision: decision)
                if decision.needsReview {
                    Section("答える") {
                        Button("OK", systemImage: "checkmark") {
                            send(.respondToDecision(epicID: epicID, decisionID: decision.id, reply: .accept))
                        }
                        ForEach(decision.alternatives, id: \.self) { alternative in
                            Button("別案にする: \(alternative)", systemImage: "arrow.triangle.branch") {
                                send(.respondToDecision(epicID: epicID, decisionID: decision.id, reply: .alternative(alternative)))
                            }
                        }
                        Button("直してほしい…", systemImage: "pencil") {
                            textRequest = TextRequest(
                                title: "直してほしい",
                                prompt: "どう直してほしいか",
                                purpose: .decisionFix(epicID: epicID, decisionID: decision.id)
                            )
                        }
                    }
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
    }

    private func send(_ intent: HumanIntent) {
        Task {
            await store.send(intent)
            dismiss()
        }
    }
}

/// 実機で確かめてほしいこと。マージは止めない
struct VerificationSection: View {
    let epic: Epic
    let items: [VerificationItem]

    var body: some View {
        Section {
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
