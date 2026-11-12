import AskHubKit
import SwiftUI

/// App Store で配信した版と、その後作業の進み具合。リリース文の下書きを確かめて、そのまま・直して公開する
struct ReleaseDetailView: View {
    let repositoryID: TargetRepository.ID
    let version: String

    @Environment(ClientStore.self) private var store
    @State private var isEditing = false

    var body: some View {
        if let release = store.snapshot?.release(Release.id(repositoryID, version)) {
            content(release)
        } else {
            ContentUnavailableView("この版は見つかりません", systemImage: "shippingbox")
        }
    }

    private func content(_ release: Release) -> some View {
        List {
            CardSection {
                AppHeaderView(
                    repository: store.repository(release.repositoryID),
                    subtitle: "App Store で配信 · \(release.platformSummary)",
                    iconSize: 40
                )
                // 公開を送った後に、司令塔がしばらく受け取っていない・断ったときの理由
                ReflectionStatusView(target(release))
            }
            CardSection {
                ForEach(release.steps) { step in
                    ReleaseStepRow(step: step)
                }
            } header: {
                Text("後作業")
            } footer: {
                Text("司令塔が順に進めます。develop には PR で入れ、直接は push しません")
            }
            if let notes = release.notes {
                notesSection(release, notes: notes)
            }
            if let url = release.githubReleaseURL {
                CardSection {
                    Link(destination: url) {
                        Label("GitHub Release を開く", systemImage: "safari")
                    }
                    if let pull = release.nextVersion?.pullRequest,
                       let pullURL = store.repository(release.repositoryID)?.pullRequestURL(pull) {
                        Link(destination: pullURL) {
                            Label("版を上げる PR #\(pull) を開く", systemImage: "arrow.triangle.pull")
                        }
                    }
                }
            }
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("\(release.version) の配信")
        .sheet(isPresented: $isEditing) {
            if let notes = release.notes {
                ReleaseNotesSheet(release: release, notes: notes) { isEditing = false }
            }
        }
    }

    private func target(_ release: Release) -> IntentTarget {
        .release(repositoryID: release.repositoryID, version: release.version)
    }

    @ViewBuilder private func notesSection(_ release: Release, notes: Release.Notes) -> some View {
        CardSection {
            RenderedBodyView(content: RenderedBody(body: notes.confirmed ?? notes.draft))
            if release.awaitsNotesReview, store.supports(publishIntent(release, notes: notes, text: notes.draft)) {
                Button("このまま公開する", systemImage: "paperplane") {
                    Task { await store.send(publishIntent(release, notes: notes, text: notes.draft)) }
                }
                .accessibilityIdentifier("release-publish")
                Button("直して公開する…", systemImage: "pencil") { isEditing = true }
                    .accessibilityIdentifier("release-edit")
            }
        } header: {
            Text(notes.confirmed == nil ? "リリース文の下書き" : "公開するリリース文")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(notes.previousTag.map { "\($0) からの変更をもとに、Claude が下書きしました" } ?? "初めての配信なので、アプリでできることをもとに、Claude が下書きしました")
                Text("public の GitHub Release に載り、消しても版が残ります。人の名前・URL・内部の話が入っていないか確かめてください")
            }
        }
        .disabled(store.isReflecting([target(release)]))
    }

    private func publishIntent(_ release: Release, notes: Release.Notes, text: String) -> HumanIntent {
        .publishRelease(repositoryID: release.repositoryID, version: release.version, notesVersion: notes.version, notes: text)
    }
}

/// 後作業の 1 段取り
private struct ReleaseStepRow: View {
    let step: Release.StepStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).appFont(.headline, weight: .semibold)
                Text(step.detail)
                    .foregroundStyle(step.state == .problem ? Theme.danger : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    private var symbol: String {
        switch step.state {
        case .done: "checkmark.circle.fill"
        case .working: "clock"
        case .waitingHuman: "person.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch step.state {
        case .done: Theme.Tone.mint
        case .working: .secondary
        case .waitingHuman: Theme.Tone.lavender
        case .problem: Theme.danger
        }
    }

    private var stateLabel: String {
        switch step.state {
        case .done: "済み"
        case .working: "進めています"
        case .waitingHuman: "あなたの番"
        case .problem: "人が直す必要があります"
        }
    }
}

/// リリース文を直して公開するシート。下書きを入れた状態で開く
private struct ReleaseNotesSheet: View {
    let release: Release
    let notes: Release.Notes
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var text = ""
    @State private var sending = SheetSendState()

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { publish() }
                    }
                }
                Section {
                    TextEditor(text: $text)
                        .font(.body.monospaced())
                        .frame(minHeight: 240)
                        .accessibilityIdentifier("release-notes-editor")
                } footer: {
                    Text("Markdown で書けます。public の GitHub Release に載ります")
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("\(release.version) のリリース文")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("公開する", isSending: sending.isSending) { publish() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if text.isEmpty { text = notes.draft }
            }
        }
        .sheetSending(sending)
        .sheetSize(.form)
    }

    private func publish() {
        let intent = HumanIntent.publishRelease(
            repositoryID: release.repositoryID, version: release.version, notesVersion: notes.version, notes: text
        )
        if sending.submit(intent, in: store) { onClose() }
    }
}
