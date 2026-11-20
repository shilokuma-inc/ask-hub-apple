import SwiftUI

/// What's New・掲載文・ビルドを確かめ、配信の方式を選んで審査に出すシート。下書きと案を入れた状態で開く
struct SubmitReviewSheet: View {
    let submission: Submission
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var texts: [String: String] = [:]
    /// 言語ごとの、変える掲載文の欄と文（無い欄は変えない）。開いたときに案を入れる
    @State private var listing: [String: [Submission.ListingField: String]] = [:]
    @State private var loadedListing = false
    /// App Review の情報の直し（nil なら変えない）。開いたときに案を入れる
    @State private var appReview: Submission.ReviewInfo?
    /// 案を入れたときの準備の版。開いている間に司令塔が案を書き直したら、送るときに断られる（古い案のまま出さない）
    @State private var loadedRevision: Int?
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
                listingSection
                // 案があるときだけ出す（変わったときだけ人が直す）
                if let review = submission.appReview, review.draft != nil {
                    AppReviewEditor(review: review, change: $appReview)
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
                Text("司令塔が App Store Connect に、版・ビルド・What's New・掲載文と App Review の情報の直しを書いて提出します。審査を待っている・審査中なら取り下げられます")
            }
            .onAppear {
                if platforms.isEmpty { platforms = Set(submission.builds.map(\.platform)) }
                if !loadedListing {
                    loadedListing = true
                    loadedRevision = submission.revision
                    appReview = submission.appReview?.draft
                    for draft in submission.listing?.drafts ?? [] { listing[draft.locale] = draft.values }
                }
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
        let whatsNew = (submission.drafts ?? []).allSatisfy { draft in
            let text = (texts[draft.locale] ?? draft.text).trimmingCharacters(in: .whitespacesAndNewlines)
            return !text.isEmpty && text.unicodeScalars.count <= 4_000
        }
        let listingIsValid = listing.values.allSatisfy { values in values.allSatisfy { field, text in field.accepts(text) } }
        return !platforms.isEmpty && whatsNew && listingIsValid && AppReviewEditor.accepts(appReview)
    }

    /// 掲載文の案。言語ごとに開いて、欄ごとに変えるかを選んで直す
    @ViewBuilder private var listingSection: some View {
        if let draft = submission.listing {
            Section {
                if draft.current.isEmpty {
                    Text("初めての版なので、掲載文は App Store Connect で書きます").foregroundStyle(.secondary)
                } else {
                    Text(draft.reason).appFont(.footnote).foregroundStyle(.secondary)
                    ForEach(draft.current) { current in
                        NavigationLink {
                            ListingLocaleEditor(
                                current: current,
                                draft: draft.drafts.first { $0.locale == current.locale },
                                changes: changes(for: current.locale)
                            )
                        } label: {
                            LabeledContent(current.localeName, value: listingSummary(of: current.locale))
                        }
                        .accessibilityIdentifier("listing-\(current.locale)")
                    }
                }
            } header: {
                Text("掲載文（説明文・キーワード・プロモーションテキスト）")
            } footer: {
                if !draft.current.isEmpty {
                    Text("案の無い言語・欄も、開いて直せます。変えた欄だけを App Store Connect に書きます")
                }
            }
        }
    }

    private func listingSummary(of locale: String) -> String {
        guard let values = listing[locale], !values.isEmpty else { return "変えない" }
        let fields = Submission.ListingTexts(locale: locale, values: values).fieldSummary
        let invalid = values.contains { field, text in !field.accepts(text) }
        return invalid ? "\(fields)（長さを直す）" : "\(fields)を変える"
    }

    private func changes(for locale: String) -> Binding<[Submission.ListingField: String]> {
        Binding { listing[locale] ?? [:] } set: { listing[locale] = $0.isEmpty ? nil : $0 }
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
            revision: loadedRevision ?? submission.revision,
            builds: submission.builds.filter { platforms.contains($0.platform) },
            whatsNew: (submission.drafts ?? []).map { Submission.Localized(locale: $0.locale, text: texts[$0.locale] ?? $0.text) },
            releaseType: releaseType,
            listing: (submission.listing?.current ?? []).compactMap { current in
                guard let values = listing[current.locale], !values.isEmpty else { return nil }
                return Submission.ListingTexts(locale: current.locale, values: values)
            },
            appReview: appReview
        )
        let intent = HumanIntent.submitForReview(repositoryID: submission.repositoryID, version: submission.version, request: request)
        if sending.submit(intent, in: store) { onClose() }
    }
}

/// 1 つの言語の掲載文を、欄ごとに「変える」を選んで直す。変えるにすると、案（無ければ今の文）を入れる
struct ListingLocaleEditor: View {
    let current: Submission.ListingTexts
    let draft: Submission.ListingTexts?
    @Binding var changes: [Submission.ListingField: String]

    var body: some View {
        Form {
            ForEach(Submission.ListingField.allCases) { field in
                Section {
                    Toggle("変える", isOn: isChanging(field))
                        .accessibilityIdentifier("listing-change-\(field.rawValue)")
                    if let text = changes[field] {
                        TextEditor(text: Binding { text } set: { changes[field] = $0 })
                            .frame(minHeight: field == .description ? 160 : 60)
                            .accessibilityIdentifier("listing-text-\(field.rawValue)")
                        DisclosureGroup("今の文") {
                            Text(current.values[field] ?? "（空）").foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    } else {
                        Text(current.values[field] ?? "（空）").foregroundStyle(.secondary).lineLimit(6)
                    }
                } header: {
                    Text(field.label)
                } footer: {
                    footer(field)
                }
            }
        }
        .formStyle(.grouped)
        .pastelBackground()
        .navigationTitle(current.localeName)
    }

    private func footer(_ field: Submission.ListingField) -> Text {
        guard let text = changes[field] else {
            return Text(draft?.values[field] != nil ? "案があります。「変える」にすると入ります" : "今の文のままにします")
        }
        let usage = field.usage(of: text.trimmingCharacters(in: .whitespacesAndNewlines))
        return Text(field.accepts(text) ? usage : "\(usage)。\(field.rangeLabel)で書いてください")
    }

    private func isChanging(_ field: Submission.ListingField) -> Binding<Bool> {
        Binding { changes[field] != nil } set: { isOn in
            changes[field] = isOn ? (draft?.values[field] ?? current.values[field] ?? "") : nil
        }
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
                    Label("What's New と掲載文の案を言語ごとに下書きします", systemImage: "text.bubble")
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
