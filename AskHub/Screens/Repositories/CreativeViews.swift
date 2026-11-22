import SwiftUI

/// リポジトリの画面の「App Store のヘッダーと検索結果」の節。まだ頼んでいなければ「作る」、あれば様子と「見る」
struct CreativeRepositorySection: View {
    let repository: TargetRepository

    @Environment(ClientStore.self) private var store
    @State private var confirmsFirst = false

    var body: some View {
        let creative = store.snapshot?.creative(of: repository.id)
        CardSection {
            if let creative {
                NavigationLink(value: AppRoute.creative(repository.id)) {
                    LabeledContent("今の様子") {
                        Text(creative.status).foregroundStyle(creative.awaitsReview ? Theme.accent : .secondary)
                    }
                }
                ReflectionStatusView(.creative(repository.id))
            } else {
                let intent = HumanIntent.draftCreativeAssets(repositoryID: repository.id, revision: 0, comment: nil)
                Button("ヘッダーと検索結果の画像を作る…", systemImage: "photo.on.rectangle.angled") { confirmsFirst = true }
                    .disabled(!store.supports(intent) || store.isReflecting(intent))
                ReflectionStatusView(.creative(repository.id))
            }
        } header: {
            Text("App Store のヘッダーと検索結果")
        } footer: {
            Text("iOS 27 以降の App Store に出る、プロダクトページのヘッダーと検索結果の画像です。Claude が案を作り、GitHub Actions で書き出します")
        }
        .confirmationDialog("ヘッダーと検索結果の案を作りますか？", isPresented: $confirmsFirst, titleVisibility: .visible) {
            Button("案を作る") {
                Task { await store.send(.draftCreativeAssets(repositoryID: repository.id, revision: 0, comment: nil)) }
            }
        } message: {
            Text("Claude がアプリと掲載文を読んで文言・色・使う画面を決め、GitHub Actions で 6.9 インチの画面を撮って書き出します（30 分ほど）。"
                + "App Store には、承認して次のリリースで審査に出すまで出ません")
        }
    }
}

/// クリエイティブアセットの案を確かめる画面。言語ごとに 2 枚の画像を並べ、前の案・承認した案・今の App Store と見比べる。
/// 直してほしいことを書くと Claude が直した案を作り、承認すると次のリリースで載せる
struct CreativeView: View {
    let repositoryID: TargetRepository.ID

    @Environment(ClientStore.self) private var store
    @Environment(\.openURL) private var openURL
    @State private var locale: String?
    @State private var version: VersionChoice = .current
    @State private var showsSafeArea = false
    @State private var revising: Int?
    @State private var confirmsApproval: Int?

    /// 見比べる案
    enum VersionChoice: Hashable {
        case current
        case previous
        case approved
        case live
    }

    var body: some View {
        if let creative = store.snapshot?.creative(of: repositoryID) {
            let selected = locale ?? creative.locales.first
            List {
                CreativeStatusSection(creative: creative)
                if !creative.locales.isEmpty {
                    CardSection {
                        if creative.locales.count > 1 {
                            Picker("言語", selection: Binding(get: { selected ?? "" }, set: { locale = $0 })) {
                                ForEach(creative.locales, id: \.self) { Text(Self.localeName($0)).tag($0) }
                            }
                        }
                        Picker("見る案", selection: $version) {
                            ForEach(choices(creative), id: \.self) { Text(title(of: $0, in: creative)).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Toggle("安全領域の枠を出す", isOn: $showsSafeArea)
                    } footer: {
                        Text("安全領域は、端末によらず切れない範囲です。文字はこの中に収めます（外は端末によって切れます）")
                    }
                    ForEach(CreativeOverview.Kind.allCases, id: \.self) { kind in
                        CreativeImageSection(
                            kind: kind,
                            image: images(of: creative).first { $0.locale == selected && $0.kind == kind },
                            showsSafeArea: showsSafeArea
                        )
                    }
                }
                CreativeActionsSection(creative: creative, revising: $revising, confirmsApproval: $confirmsApproval)
            }
            .pastelBackground()
            .compactList()
            .navigationTitle("ヘッダーと検索結果")
            .sheet(item: Binding(get: { revising.map(RevisionRequest.init) }, set: { revising = $0?.revision })) { request in
                CreativeRevisionSheet(repositoryID: repositoryID, revision: request.revision) { revising = nil }
            }
            .confirmationDialog(
                "この案を承認しますか？",
                isPresented: Binding(get: { confirmsApproval != nil }, set: { if !$0 { confirmsApproval = nil } }),
                titleVisibility: .visible,
                presenting: confirmsApproval
            ) { revision in
                Button("案 \(revision) を承認する") {
                    Task { await store.send(.approveCreativeAssets(repositoryID: repositoryID, revision: revision)) }
                }
            } message: { _ in
                Text("司令塔が画像を App Store Connect のライブラリに上げておき、次のリリースの「審査に出す」で載せます。"
                    + "ライブラリの画像は、審査に出すまで App Store に出ません")
            }
        } else {
            ContentUnavailableView("ヘッダーと検索結果の案はまだありません", systemImage: "photo.on.rectangle.angled")
        }
    }

    private struct RevisionRequest: Identifiable {
        var revision: Int
        var id: Int { revision }
    }

    private func choices(_ creative: CreativeOverview) -> [VersionChoice] {
        var choices: [VersionChoice] = [.current]
        if creative.previous != nil { choices.append(.previous) }
        if let approved = creative.approved, approved.revision != creative.draft?.revision { choices.append(.approved) }
        if !creative.live.isEmpty { choices.append(.live) }
        return choices
    }

    private func title(of choice: VersionChoice, in creative: CreativeOverview) -> String {
        switch choice {
        case .current: "今の案"
        case .previous: "前の案 \(creative.previous?.revision ?? 0)"
        case .approved: "承認した案 \(creative.approved?.revision ?? 0)"
        case .live: "今の App Store"
        }
    }

    private func images(of creative: CreativeOverview) -> [CreativeOverview.Image] {
        switch version {
        case .current: creative.draft?.images.isEmpty == false ? creative.draft?.images ?? [] : creative.approved?.images ?? []
        case .previous: creative.previous?.images ?? []
        case .approved: creative.approved?.images ?? []
        case .live: creative.live
        }
    }

    /// 言語の名前（端末の言語で）。分からなければコードのまま
    static func localeName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code).map { "\($0)（\(code)）" } ?? code
    }
}

/// 今の様子・Claude の説明・案ぜんたいの問題
private struct CreativeStatusSection: View {
    let creative: CreativeOverview

    @Environment(ClientStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        CardSection {
            LabeledContent("今の様子") { Text(creative.status).foregroundStyle(.secondary) }
            if let draft = creative.draft {
                if let comment = draft.comment {
                    LabeledContent("頼んだ直し") { Text(comment).foregroundStyle(.secondary) }
                }
                if let reason = draft.reason {
                    Text(reason).appFont(.callout)
                }
                if let failure = draft.failure {
                    Label(failure, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.warning)
                }
                ForEach(draft.problems, id: \.self) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
                if let url = draft.runURL {
                    Button("書き出しの実行を GitHub で見る") { openURL(url) }
                }
            }
            if let approved = creative.approved, let total = approved.libraryTotal, let ready = approved.libraryReady {
                LabeledContent("App Store Connect のライブラリ", value: "\(ready) / \(total) 枚")
            }
            if let problem = creative.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            ReflectionStatusView(.creative(creative.repositoryID))
        } header: {
            Text("案")
        }
    }
}

/// 1 枚の画像（縦横の比の合う枠に入れ、安全領域の枠を重ねられる）と、その画像の問題
private struct CreativeImageSection: View {
    let kind: CreativeOverview.Kind
    let image: CreativeOverview.Image?
    let showsSafeArea: Bool

    var body: some View {
        CardSection {
            if let image {
                CreativeImageView(image: image, showsSafeArea: showsSafeArea)
                ForEach(image.problems, id: \.self) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .appFont(.caption)
                        .foregroundStyle(Theme.warning)
                }
            } else {
                Text("この言語の画像はありません").foregroundStyle(.secondary)
            }
        } header: {
            Text(kind.title)
        }
    }
}

/// クリエイティブアセットの画像（状態リポジトリの見本か、App Store Connect の画像）
struct CreativeImageView: View {
    let image: CreativeOverview.Image
    var showsSafeArea = false

    var body: some View {
        Group {
            switch image.screenshot {
            case let .stored(path):
                StoredScreenshotImage(path: path)
            case let .remote(url):
                AsyncImage(url: url) { phase in
                    if let loaded = phase.image {
                        loaded.resizable().scaledToFit()
                    } else {
                        ProgressView()
                    }
                }
            case .demo:
                Color.secondary.opacity(0.2)
            }
        }
        .aspectRatio(image.kind.aspectRatio, contentMode: .fit)
        .overlay {
            if showsSafeArea {
                GeometryReader { proxy in
                    let area = image.kind.safeArea
                    Rectangle()
                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                        .foregroundStyle(.yellow)
                        .frame(width: proxy.size.width * area.width, height: proxy.size.height * area.height)
                        .offset(x: proxy.size.width * area.minX, y: proxy.size.height * area.minY)
                }
                .accessibilityLabel("安全領域")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("creative-\(image.locale)-\(image.kind.rawValue)")
    }
}

/// 「直してもらう」「承認する」「作り直す」
private struct CreativeActionsSection: View {
    let creative: CreativeOverview
    @Binding var revising: Int?
    @Binding var confirmsApproval: Int?

    @Environment(ClientStore.self) private var store

    var body: some View {
        let revision = creative.draft?.revision ?? 0
        let approve = HumanIntent.approveCreativeAssets(repositoryID: creative.repositoryID, revision: revision)
        let reflecting = store.isReflecting([.creative(creative.repositoryID)])
        CardSection {
            if store.supports(approve) {
                Button("この案を承認する…", systemImage: "checkmark.seal") { confirmsApproval = revision }
                    .disabled(reflecting)
            }
            let redraft = HumanIntent.draftCreativeAssets(repositoryID: creative.repositoryID, revision: revision, comment: nil)
            if !creative.isWorking, store.supports(redraft) {
                Button("直してもらう…", systemImage: "text.bubble") { revising = revision }
                    .disabled(reflecting)
            }
            if creative.isWorking {
                Text("案を作っている間は、直しを頼めません。書き出し終わると、ここで確かめられます").foregroundStyle(.secondary)
            }
        } footer: {
            if creative.approved != nil, !creative.awaitsReview {
                Text("承認した案は、次のリリースの「審査に出す」で載せます")
            }
        }
    }
}

/// 直してほしいことを書いて、Claude に直した案を作ってもらうシート
struct CreativeRevisionSheet: View {
    let repositoryID: TargetRepository.ID
    /// 人が見た案の版
    let revision: Int
    let onClose: () -> Void

    @Environment(ClientStore.self) private var store
    @State private var comment = ""
    @State private var sending = SheetSendState()

    var body: some View {
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { send() }
                    }
                }
                Section {
                    TextEditor(text: $comment)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("creative-comment")
                } header: {
                    Text("直してほしいこと")
                } footer: {
                    Text("例: 見出しをもっと短く。英語は動詞から始めて。背景をアプリの色に近づけて。空のまま送ると、Claude が別の案を作ります")
                }
            }
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("案 \(revision) の直し")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onClose)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("直してもらう", isSending: sending.isSending) { send() }
                        .disabled(trimmed.unicodeScalars.count > 2000)
                }
            }
        }
        .sheetSending(sending)
        .sheetSize(.form)
    }

    private var trimmed: String { comment.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func send() {
        let comment = trimmed.isEmpty ? nil : trimmed
        let intent = HumanIntent.draftCreativeAssets(repositoryID: repositoryID, revision: revision, comment: comment)
        if sending.submit(intent, in: store) { onClose() }
    }
}
