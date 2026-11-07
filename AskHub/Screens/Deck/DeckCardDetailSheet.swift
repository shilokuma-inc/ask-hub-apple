import SwiftUI

/// カードの全文（質問の選択肢ごとの違い・説明の履歴・Before / After の大きな画像 など）
struct DeckCardDetailSheet: View {
    let card: DeckCard

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                CardSection {
                    AppHeaderView(repository: store.repository(card.repositoryID), subtitle: store.epic(card.epicID)?.title ?? "")
                    if let epic = store.epic(card.epicID) {
                        LabeledContent("依頼", value: epic.request.summary)
                    }
                }
                switch card.content {
                case .question(let question):
                    QuestionDetailSections(question: question, epic: store.epic(card.epicID))

                case .decision(let decision):
                    DecisionDetailSections(decision: decision)

                case .verification(let item):
                    CardSection("確かめること") {
                        Text(item.text)
                        LabeledContent("手順", value: item.steps)
                    }
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle(card.kindLabel)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

/// 質問の全文。epic の画面からも使う
struct QuestionDetailSections: View {
    let question: Question
    let epic: Epic?

    var body: some View {
        CardSection(question.title) {
            LabeledContent("なぜ決めるか", value: question.why)
            if let reason = question.recommendationReason {
                LabeledContent("推奨の理由", value: reason)
            }
            if let note = question.revisionNote {
                Label(note, systemImage: "pencil.and.list.clipboard")
                    .foregroundStyle(Theme.warning)
            }
        }
        if !question.options.isEmpty {
            CardSection("選択肢ごとの違い") {
                ForEach(question.options) { option in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(option.label).rowFont(.title)
                            if option.id == question.recommendedOptionID {
                                TagLabel(text: "推奨", tint: Theme.success)
                            }
                        }
                        Text(option.effect).foregroundStyle(.secondary)
                    }
                }
            }
        }
        dependencySection
        if !question.explanations.isEmpty {
            CardSection("説明") {
                ForEach(Array(question.explanations.enumerated()), id: \.offset) { _, explanation in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(explanation.request.isEmpty ? "（説明を求めました）" : "求めた内容: \(explanation.request)")
                            .appFont(.footnote)
                            .foregroundStyle(.secondary)
                        if let body = explanation.body {
                            Text(body)
                        } else if epic?.isActive == false {
                            Text("説明を待つ間にやめました")
                                .foregroundStyle(.secondary)
                        } else if isExplaining {
                            Label("Claude がリポジトリを読んで書いています", systemImage: "hourglass")
                                .foregroundStyle(.secondary)
                        } else {
                            // 人に渡されて止まっている説明は、機械の「いま」に出ない
                            Label("説明が止まっています。epic の「対処が要ります」から選んでください", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var isExplaining: Bool {
        epic?.activities.contains { $0.kind == .explaining(question.id) } ?? true
    }

    @ViewBuilder private var dependencySection: some View {
        let dependents = epic?.questions.dependents(of: question) ?? []
        if !question.dependsOn.isEmpty || !dependents.isEmpty {
            CardSection("ほかの質問とのつながり") {
                ForEach(question.dependsOn, id: \.self) { id in
                    let dependency = epic?.question(id)
                    LabeledContent("\(id) の回答が前提", value: dependency?.statusLabel ?? "不明")
                }
                if !dependents.isEmpty {
                    Text("この回答で \(dependents.map(\.id).joined(separator: "・")) が決まります")
                }
            }
        }
    }
}

/// 判断のカードの全文。最終 PR の画面からも使う
struct DecisionDetailSections: View {
    let decision: DecisionCard

    var body: some View {
        CardSection(decision.title) {
            LabeledContent("理由", value: decision.reason)
            if let source = decision.goalSource {
                LabeledContent("ゴールのどこから", value: source)
            }
            if !decision.alternatives.isEmpty {
                LabeledContent("ほかの案", value: decision.alternatives.joined(separator: "\n"))
            }
        }
        if decision.before != nil || decision.after != nil {
            CardSection("画面の変化") {
                BeforeAfterView(before: decision.before, after: decision.after)
                    .frame(maxHeight: 420)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            }
        } else if let note = decision.screenshotNote {
            CardSection("画面の変化") {
                Label(note, systemImage: "camera.metering.unknown")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
