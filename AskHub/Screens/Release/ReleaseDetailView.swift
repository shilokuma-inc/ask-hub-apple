import AskHubKit
import SwiftUI

/// App Store で配信した版と、その後作業の進み具合。リリース文の下書きを確かめて、そのまま・直して公開する
struct ReleaseDetailView: View {
    let repositoryID: TargetRepository.ID
    let version: String

    @Environment(ClientStore.self) private var store
    @State private var isEditing = false
    @State private var isEditingPromotionalText = false
    /// hotfix を始める確かめ（hotfix の版と、一時停止する進行中のリリースの版）
    @State private var confirmingHotfix: HotfixPlan?

    struct HotfixPlan: Identifiable {
        var version: String
        var suspend: String?
        var id: String { version }
    }

    var body: some View {
        if let release = store.snapshot?.release(Release.id(repositoryID, version)) {
            content(release)
        } else {
            ContentUnavailableView("この版は見つかりません", systemImage: "shippingbox")
        }
    }

    /// 配信中の版だけを直す hotfix を始める（最も新しい配信した版だけ）。進行中のリリースがあれば、一時停止することを確かめる
    @ViewBuilder private func hotfixSection(_ release: Release) -> some View {
        let open = store.snapshot?.openRelease(of: release.repositoryID)
        if let version = store.snapshot?.hotfixVersion(of: release.repositoryID, from: release.version), open?.hotfixFrom == nil,
           store.supports(.startHotfix(repositoryID: release.repositoryID, version: version, suspend: open?.version)) {
            CardSection {
                Button("hotfix を始める…", systemImage: "bandage") {
                    confirmingHotfix = HotfixPlan(version: version, suspend: open?.version)
                }
                .accessibilityIdentifier("release-hotfix")
            } footer: {
                Text("配信中の \(release.version) だけを直す \(version) を、v\(release.version) のタグから作ります。develop には触れず、配信した後に main と develop に取り込みます")
            }
            .confirmationDialog(
                hotfixTitle,
                isPresented: Binding { confirmingHotfix != nil } set: { if !$0 { confirmingHotfix = nil } },
                titleVisibility: .visible,
                presenting: confirmingHotfix
            ) { plan in
                Button(plan.suspend == nil ? "hotfix を始める" : "一時停止して hotfix を始める") {
                    let intent = HumanIntent.startHotfix(repositoryID: release.repositoryID, version: plan.version, suspend: plan.suspend)
                    Task { await store.send(intent) }
                }
            } message: { plan in
                Text(hotfixMessage(plan))
            }
        }
    }

    private var hotfixTitle: String {
        confirmingHotfix.map { "hotfix \($0.version) を始めますか？" } ?? ""
    }

    private func hotfixMessage(_ plan: HotfixPlan) -> String {
        guard let suspend = plan.suspend else {
            return "release/\(plan.version) を作り、版を \(plan.version) に上げます。直すことは「このリリースを直す」で依頼してください"
        }
        return "進行中の \(suspend) のリリースを一時停止します。審査中なら取り下げ、App Store Connect の編集できる版を hotfix に回します。"
            + "hotfix を配信したら \(suspend) に取り込み、ビルド・What's New・掲載文の案を作り直して再開します"
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
                    StepStatusRow(title: step.title, detail: step.detail, state: step.state)
                }
            } header: {
                Text("後作業")
            } footer: {
                Text("司令塔が順に進めます。develop には PR で入れ、直接は push しません")
            }
            if let notes = release.notes {
                notesSection(release, notes: notes)
            }
            if let promotionalText = release.promotionalText {
                promotionalTextSection(release, promotionalText)
            }
            hotfixSection(release)
            links(release)
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("\(release.version) の配信")
        .sheet(isPresented: $isEditing) {
            if let notes = release.notes {
                ReleaseNotesSheet(release: release, notes: notes) { isEditing = false }
            }
        }
        .sheet(isPresented: $isEditingPromotionalText) {
            if let promotionalText = release.promotionalText {
                PromotionalTextSheet(release: release, promotionalText: promotionalText) { isEditingPromotionalText = false }
            }
        }
    }

    @ViewBuilder private func links(_ release: Release) -> some View {
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

    /// 配信中の版のプロモーションテキスト（審査に出さずに直せる）
    @ViewBuilder private func promotionalTextSection(_ release: Release, _ promotionalText: Release.PromotionalText) -> some View {
        let probe = HumanIntent.updatePromotionalText(repositoryID: release.repositoryID, version: release.version, texts: [])
        CardSection {
            ForEach(promotionalText.current) { text in
                VStack(alignment: .leading, spacing: 4) {
                    Text(text.localeName).appFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
                    Text(text.text.isEmpty ? "（空）" : text.text).foregroundStyle(text.text.isEmpty ? .secondary : .primary)
                }
            }
            if let status = Self.status(of: promotionalText.request) {
                Text(status).appFont(.footnote).foregroundStyle(.secondary)
            }
            if store.supports(probe) {
                Button("直して反映する…", systemImage: "pencil") { isEditingPromotionalText = true }
                    .accessibilityIdentifier("release-promotional-text")
            }
        } header: {
            Text("プロモーションテキスト")
        } footer: {
            Text("審査に出さずに、App Store の配信中の版にすぐ反映されます（\(Release.PromotionalText.limit) 文字まで）")
        }
    }

    private static func status(of request: Release.PromotionalTextRequest) -> String? {
        switch request {
        case .none: nil
        case .sending: "直した文を送りました。受け付けるのを待っています"
        case .writing: "App Store Connect に書いています"
        case .done(let date): "\(date.formatted(date: .abbreviated, time: .shortened)) に反映しました"
        case .failed(let reason): "App Store Connect が断りました: \(reason)"
        case .rejected(let reason): "受け付けませんでした: \(reason)"
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

/// 段取りの 1 行（配信の後作業・リリースの準備と審査）
struct StepStatusRow: View {
    let title: String
    let detail: String
    let state: Release.StepState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).appFont(.headline, weight: .semibold)
                Text(detail)
                    .foregroundStyle(state == .problem ? Theme.danger : .secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    private var symbol: String {
        switch state {
        case .done: "checkmark.circle.fill"
        case .working: "clock"
        case .waitingHuman: "person.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .done: Theme.Tone.mint
        case .working: .secondary
        case .waitingHuman: Theme.Tone.lavender
        case .problem: Theme.danger
        }
    }

    private var stateLabel: String {
        switch state {
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
