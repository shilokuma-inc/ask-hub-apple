import SwiftUI

/// リリースを始めた版の準備と審査。準備がそろったら What's New とビルドを確かめて審査に出し、審査に通ったら配信する。
/// 審査を待っている・審査中なら取り下げ、出す前・取り下げた後・断られた後ならやめられる
struct SubmissionDetailView: View {
    let repositoryID: TargetRepository.ID
    let version: String

    @Environment(ClientStore.self) private var store
    @State private var isSubmitting = Self.initialSubmitting
    @State private var confirming: Confirmation?

    /// 撮影では、起動引数で審査に出すシートを開いておく
    private static var initialSubmitting: Bool {
        #if DEBUG
        DemoLaunch.initialSheet() == .submitReview
        #else
        false
        #endif
    }

    /// 取り消しにくい操作の確かめ
    private enum Confirmation: String, Identifiable {
        case distribute
        case withdraw
        case abandon

        var id: String { rawValue }
    }

    var body: some View {
        if let submission = store.snapshot?.submission(Submission.id(repositoryID, version)) {
            content(submission)
        } else {
            ContentUnavailableView("このリリースは見つかりません", systemImage: "shippingbox")
        }
    }

    private func content(_ submission: Submission) -> some View {
        List {
            CardSection {
                AppHeaderView(repository: store.repository(submission.repositoryID), iconSize: 40) {
                    Text(submission.startedInAskHub ? "リリース \(submission.version)" : "\(submission.version)（App Store Connect で審査に出した版）")
                        .appFont(.footnote)
                        .foregroundStyle(.secondary)
                }
                // 操作を送った後に、司令塔がしばらく受け取っていない・断ったときの理由
                ReflectionStatusView(target(submission))
            }
            actions(submission)
            CardSection {
                ForEach(submission.steps) { step in
                    StepStatusRow(title: step.title, detail: step.detail, state: step.state)
                }
            } header: {
                Text("進み具合")
            } footer: {
                Text(submission.startedInAskHub
                    ? "司令塔が順に進めます。App Store Connect に書くのは、あなたが審査に出す・配信する・取り下げを押したときだけです"
                    : "App Store Connect で手で審査に出した版です。審査の状態を 30 分ごとに読み、変わったら知らせます")
            }
            whatsNewSection(submission)
            links(submission)
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("\(submission.version) のリリース")
        .sheet(isPresented: $isSubmitting) {
            SubmitReviewSheet(submission: submission) { isSubmitting = false }
        }
        .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: confirming) { action in
            confirmationButton(action, submission: submission)
        } message: { action in
            Text(confirmationMessage(action))
        }
    }

    private func target(_ submission: Submission) -> IntentTarget {
        .submission(repositoryID: submission.repositoryID, version: submission.version)
    }

    // MARK: - 操作

    @ViewBuilder private func actions(_ submission: Submission) -> some View {
        let id = submission.repositoryID
        let probe = Submission.SubmitRequest(revision: submission.revision, builds: [], whatsNew: [], releaseType: .afterApproval)
        let canSubmit = submission.awaitsSubmission && submission.sending == nil
            && store.supports(.submitForReview(repositoryID: id, version: submission.version, request: probe))
        let canDistribute = submission.awaitsDistribution && submission.sending == nil
            && store.supports(.distributeRelease(repositoryID: id, version: submission.version))
        let canWithdraw = submission.canWithdraw && submission.sending == nil
            && store.supports(.withdrawSubmission(repositoryID: id, version: submission.version))
        let canAbandon = submission.canAbandon && submission.sending == nil
            && store.supports(.abandonRelease(repositoryID: id, version: submission.version))
        if canSubmit || canDistribute || canWithdraw || canAbandon {
            CardSection {
                if canSubmit {
                    Button("確かめて審査に出す…", systemImage: "paperplane") { isSubmitting = true }
                        .accessibilityIdentifier("submission-submit")
                }
                if canDistribute {
                    Button("配信する…", systemImage: "shippingbox") { confirming = .distribute }
                        .accessibilityIdentifier("submission-distribute")
                }
                if canWithdraw {
                    Button("審査を取り下げる…", systemImage: "arrow.uturn.backward") { confirming = .withdraw }
                        .accessibilityIdentifier("submission-withdraw")
                }
                if canAbandon {
                    Button("このリリースをやめる…", systemImage: "xmark.circle", role: .destructive) { confirming = .abandon }
                        .accessibilityIdentifier("submission-abandon")
                }
            } header: {
                Text("あなたの番")
            }
            .disabled(store.isReflecting([target(submission)]))
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding { confirming != nil } set: { if !$0 { confirming = nil } }
    }

    private var confirmationTitle: String {
        switch confirming {
        case .distribute: "App Store で配信しますか？"
        case .withdraw: "審査を取り下げますか？"
        case .abandon: "このリリースをやめますか？"
        case nil: ""
        }
    }

    private func confirmationMessage(_ action: Confirmation) -> String {
        switch action {
        case .distribute: "配信すると取り消せません。24 時間ほどで App Store に出ます"
        case .withdraw: "審査の待ちの順番は失われます。取り下げた後は、ビルドや What's New を直して審査に出し直せます"
        case .abandon: "記録を終わりにするだけで、release ブランチと App Store Connect の版は残します。次のリリースを始められるようになります"
        }
    }

    @ViewBuilder private func confirmationButton(_ action: Confirmation, submission: Submission) -> some View {
        let id = submission.repositoryID
        switch action {
        case .distribute:
            Button("配信する") { send(.distributeRelease(repositoryID: id, version: submission.version)) }
        case .withdraw:
            Button("取り下げる", role: .destructive) { send(.withdrawSubmission(repositoryID: id, version: submission.version)) }
        case .abandon:
            Button("やめる", role: .destructive) { send(.abandonRelease(repositoryID: id, version: submission.version)) }
        }
    }

    private func send(_ intent: HumanIntent) {
        Task { await store.send(intent) }
    }

    // MARK: - What's New・リンク

    @ViewBuilder private func whatsNewSection(_ submission: Submission) -> some View {
        let texts = submission.submitted?.whatsNew ?? submission.drafts ?? []
        if !texts.isEmpty {
            CardSection {
                ForEach(texts) { text in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(text.localeName).appFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
                        Text(text.text)
                    }
                }
            } header: {
                Text(submission.submitted == nil ? "What's New の下書き" : "審査に出した What's New")
            } footer: {
                if let submitted = submission.submitted {
                    let builds = submitted.builds.map { "\($0.platform) (\($0.build))" }.joined(separator: "・")
                    Text("ビルド \(builds) · 配信の方式: \(submitted.releaseType.label)")
                } else {
                    Text("審査に出すときに、言語ごとに直せます。配信した後の GitHub Release にも、審査に出したときの日本語の文を載せます")
                }
            }
        }
    }

    @ViewBuilder private func links(_ submission: Submission) -> some View {
        let repository = store.repository(submission.repositoryID)
        let branchURL = submission.branch.flatMap { branch in repository.flatMap { URL(string: "https://github.com/\($0.fullName)/tree/\(branch)") } }
        let pullURL = submission.nextVersion?.pullRequest.flatMap { repository?.pullRequestURL($0) }
        if branchURL != nil || pullURL != nil {
            CardSection {
                if let branchURL, let branch = submission.branch {
                    Link(destination: branchURL) { Label("\(branch) を開く", systemImage: "arrow.triangle.branch") }
                }
                if let pullURL, let pull = submission.nextVersion?.pullRequest {
                    Link(destination: pullURL) { Label("版を上げる PR #\(pull) を開く", systemImage: "arrow.triangle.pull") }
                }
            }
        }
    }
}

/// What's New とビルドを確かめ、配信の方式を選んで審査に出すシート。下書きを入れた状態で開く
struct SubmitReviewSheet: View {
    let submission: Submission
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var texts: [String: String] = [:]
    @State private var platforms: Set<String> = []
    @State private var kind = Kind.afterApproval
    @State private var releaseDate = Self.defaultReleaseDate
    @State private var isConfirming = false
    @State private var sending = SheetSendState()

    enum Kind: Hashable {
        case afterApproval
        case manual
        case scheduled
    }

    /// 日時を指定するときの既定（明日の 10 時）
    static var defaultReleaseDate: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return calendar.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { isConfirming = true }
                    }
                }
                Section {
                    ForEach(submission.builds) { build in
                        Toggle(isOn: binding(for: build.platform)) {
                            Text("\(build.platform)（ビルド \(build.build)）")
                        }
                    }
                } header: {
                    Text("ビルド")
                } footer: {
                    Text("release ブランチから上げた、最新のビルドです")
                }
                ForEach(submission.drafts ?? []) { draft in
                    Section {
                        TextEditor(text: text(for: draft))
                            .frame(minHeight: 120)
                            .accessibilityIdentifier("whats-new-\(draft.locale)")
                    } header: {
                        Text("What's New · \(draft.localeName)")
                    } footer: {
                        Text("\((texts[draft.locale] ?? draft.text).count) / 4,000 文字。App Store に載ります")
                    }
                }
                Section {
                    Picker("配信の方式", selection: $kind) {
                        Text("承認後すぐ").tag(Kind.afterApproval)
                        Text("手動").tag(Kind.manual)
                        Text("日時を指定").tag(Kind.scheduled)
                    }
                    .accessibilityIdentifier("submission-release-type")
                    if kind == .scheduled {
                        DatePicker("配信の日時", selection: $releaseDate, in: Date()...)
                    }
                } header: {
                    Text("審査に通った後")
                } footer: {
                    Text(kindFooter)
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("\(submission.version) を審査に出す")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("審査に出す", isSending: sending.isSending) { isConfirming = true }
                        .disabled(!isReady)
                }
            }
            .confirmationDialog("App Store の審査に出しますか？", isPresented: $isConfirming, titleVisibility: .visible) {
                Button("審査に出す") { submit() }
            } message: {
                Text("司令塔が App Store Connect に、版・ビルド・What's New を書いて提出します。審査を待っている・審査中なら取り下げられます")
            }
            .onAppear {
                if platforms.isEmpty { platforms = Set(submission.builds.map(\.platform)) }
            }
        }
        .sheetSending(sending)
        .sheetSize(.page)
    }

    private var kindFooter: String {
        switch kind {
        case .afterApproval: "審査に通ったら、すぐ App Store で配信されます"
        case .manual: "審査に通ったら知らせます。AskHub で「配信する」を押すと配信します"
        case .scheduled: "審査に通ったら、この日時より後に配信されます"
        }
    }

    private var isReady: Bool {
        !platforms.isEmpty && (submission.drafts ?? []).allSatisfy { draft in
            let text = (texts[draft.locale] ?? draft.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.unicodeScalars.count <= 4_000
        }
    }

    private func binding(for platform: String) -> Binding<Bool> {
        Binding { platforms.contains(platform) } set: { isOn in
            if isOn { platforms.insert(platform) } else { platforms.remove(platform) }
        }
    }

    private func text(for draft: Submission.Localized) -> Binding<String> {
        Binding { texts[draft.locale] ?? draft.text } set: { texts[draft.locale] = $0 }
    }

    private func submit() {
        let releaseType: Submission.ReleaseType = switch kind {
        case .afterApproval: .afterApproval
        case .manual: .manual
        case .scheduled: .scheduled(releaseDate)
        }
        let request = Submission.SubmitRequest(
            revision: submission.revision,
            builds: submission.builds.filter { platforms.contains($0.platform) },
            whatsNew: (submission.drafts ?? []).map { Submission.Localized(locale: $0.locale, text: texts[$0.locale] ?? $0.text) },
            releaseType: releaseType
        )
        let intent = HumanIntent.submitForReview(repositoryID: submission.repositoryID, version: submission.version, request: request)
        if sending.submit(intent, in: store) { onClose() }
    }
}

/// リリースを始めるシート。版の既定は、前に配信した版の次のマイナー
struct StartReleaseSheet: View {
    let repository: TargetRepository
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var version = ""
    @State private var sending = SheetSendState()

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { start() }
                    }
                }
                Section {
                    TextField("版", text: $version, prompt: Text("1.4.0"))
                        .labelsHidden()
                        .accessibilityIdentifier("release-version")
                } header: {
                    Text("始める版")
                } footer: {
                    Text(canStart ? "前に配信した版より大きい版にします（既定は次のマイナー）" : "前に配信した版より大きい、1.4.0 のような版にしてください")
                }
                Section {
                    let branch = "release/\(version.isEmpty ? "<版>" : version)"
                    Label("develop の先頭から \(branch) を作り、TestFlight に上げます", systemImage: "arrow.triangle.branch")
                    Label("develop の版を次に上げる PR を出します", systemImage: "arrow.triangle.pull")
                    Label("What's New を言語ごとに下書きします", systemImage: "text.bubble")
                    Label("ビルドができたら「あなたの番」で審査に出せます", systemImage: "person.fill")
                } header: {
                    Text("司令塔がすること")
                } footer: {
                    Text("App Store Connect にはまだ何も書きません。審査に出すときに、あなたが確かめてから書きます")
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("リリースを始める")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("始める", isSending: sending.isSending) { start() }
                        .disabled(!canStart)
                }
            }
            .onAppear {
                if version.isEmpty { version = store.snapshot?.suggestedReleaseVersion(of: repository.id) ?? "1.0.0" }
            }
        }
        .sheetSending(sending)
        .sheetSize(.form)
    }

    private var canStart: Bool {
        let version = version.trimmingCharacters(in: .whitespaces)
        return Submission.isVersion(version) && store.supports(.startRelease(repositoryID: repository.id, version: version))
    }

    private func start() {
        let intent = HumanIntent.startRelease(repositoryID: repository.id, version: version.trimmingCharacters(in: .whitespaces))
        if sending.submit(intent, in: store) { onClose() }
    }
}
