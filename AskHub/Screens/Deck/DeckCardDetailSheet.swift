import SwiftUI

/// カードの全文（質問の選択肢ごとの違い・説明の履歴・Before / After の大きな画像 など）
struct DeckCardDetailSheet: View {
    let card: DeckCard
    /// 選択肢を選んだとき（実機確認だけ、シートからも答えられる）。選択肢の添字を渡す
    var onChoose: ((Int) -> Void)?

    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                switch card.content {
                case .question(let question):
                    requestSection
                    QuestionDetailSections(question: question, epic: store.epic(card.epicID))

                case .decision(let decision):
                    requestSection
                    DecisionDetailSections(decision: decision)

                case .verification(let item):
                    // 実機を手に持って確かめるので、確かめることを先に出す。依頼の要約（実装の細部を含む）は後ろに置く
                    CardSection("確かめること") {
                        Text(item.text)
                        // 状態リポジトリの項目（ゴールの完了の条件）には手順が無い
                        if !item.steps.isEmpty {
                            LabeledContent("手順", value: item.steps)
                        }
                    }
                    if let onChoose {
                        // 読んだその場で答えられるよう、カードと同じ選択肢を置く（押すとシートを閉じ、カードをその方向へ飛ばす）
                        CardSection {
                            ForEach(Array(card.choices.enumerated()), id: \.element.id) { index, choice in
                                Button {
                                    onChoose(index)
                                } label: {
                                    Label {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(choice.label).rowFont(.title)
                                            Text(choice.detail).rowFont(.detail).foregroundStyle(.secondary)
                                        }
                                    } icon: {
                                        Image(systemName: choice.id == "confirmed" ? "checkmark.circle" : "exclamationmark.bubble")
                                            .foregroundStyle(choice.id == "confirmed" ? Theme.success : Theme.warning)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("detail-choice-\(choice.id)")
                            }
                        }
                    }
                    requestSection
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle(title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
        .sheetSize(.page)
    }

    /// どのアプリのどの依頼のカードか
    private var requestSection: some View {
        CardSection {
            AppHeaderView(repository: store.repository(card.repositoryID), subtitle: store.epic(card.epicID)?.title ?? "")
            if let epic = store.epic(card.epicID) {
                LabeledContent("依頼", value: epic.request.summary)
            }
        }
    }

    /// 実機確認の種類の札には確かめる版の説明が続いて長いので、題は「実機で確かめる」だけにする（版の説明はカードに出ている）
    private var title: String {
        if case .verification = card.content {
            return "実機で確かめる"
        }
        return card.kindLabel
    }
}

/// 質問の全文。epic の画面からも使う
struct QuestionDetailSections: View {
    let question: Question
    let epic: Epic?

    var body: some View {
        CardSection(question.title) {
            if let point = question.during {
                LabeledContent("出た所", value: "\(point.label)の途中（答えるまで止めて待ちます）")
            }
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
                BeforeAfterView(before: decision.before, after: decision.after, zoomable: true)
                    .frame(maxHeight: 420)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
                if let note = decision.screenshotNote {
                    Label(note, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                }
            }
        } else if let note = decision.screenshotNote {
            CardSection("画面の変化") {
                Label(note, systemImage: "camera.metering.unknown")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
