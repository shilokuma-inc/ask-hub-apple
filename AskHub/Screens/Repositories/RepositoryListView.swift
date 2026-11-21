import SwiftUI

/// 「リポジトリ」。対象のリポジトリ（AskHub でループ開発を回すもの）を、organization ごとの見出しを付けて並べる
struct RepositoryListView: View {
    let selection: Binding<AppRoute?>?

    @Environment(ClientStore.self) private var store
    @State private var isAdding = false

    var body: some View {
        let groups = store.snapshot?.repositoryGroups ?? []
        RouteList(selection: selection) {
            ForEach(groups) { group in
                CardSection {
                    ForEach(group.repositories) { repository in
                        NavigationLink(value: AppRoute.repository(repository.id)) {
                            RepositoryRow(repository: repository)
                        }
                    }
                } header: {
                    OwnerLabel(group: group)
                } footer: {
                    if group.id == groups.last?.id {
                        Text("対象に加えても、どの Mac にも clone しません。ジョブが要るときに、その Mac でだけ取り寄せます")
                    }
                }
            }
        }
        .overlay {
            LoadStateOverlay(
                isEmpty: groups.isEmpty,
                empty: ContentUnavailableView("対象のリポジトリはありません", systemImage: "folder")
            )
        }
        .pastelBackground()
        .navigationTitle("リポジトリ")
        .toolbar {
            SectionToolbar()
            ToolbarItem(placement: .secondaryAction) {
                Button("対象に加える", systemImage: "folder.badge.plus") { isAdding = true }
            }
        }
        .sheet(isPresented: $isAdding) { AddRepositorySheet() }
        .refreshable { await store.refresh() }
    }
}

private struct RepositoryRow: View {
    let repository: TargetRepository

    @Environment(ClientStore.self) private var store

    var body: some View {
        let active = store.snapshot?.activeEpics.first { $0.repositoryID == repository.id }
        HStack(spacing: 12) {
            AppIconView(repository: repository, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repository.appName).rowFont(.title)
                    // 対象に加えたのが反映されるまでの印（断られたら赤）
                    ReflectionBadge([.repository(repository.id)])
                }
                // 持ち主は見出しに出ているので、repo の名前だけを出す。アプリ名と同じなら出さない（状態リポジトリのリポジトリはいつも同じ）
                if repository.name != repository.appName {
                    Text(repository.name)
                        .rowFont(.detail)
                        .foregroundStyle(.secondary)
                }
                if let active {
                    Text(active.title)
                        .rowFont(.subtitle)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
        }
        .compactRow()
    }
}

/// リポジトリの詳細（進めている epic・リリース）。外したリポジトリは、加え直すボタンを出す
struct RepositoryDetailView: View {
    let repositoryID: TargetRepository.ID

    @Environment(ClientStore.self) private var store
    @State private var isConfirmingRemoval = false
    @State private var isEditingBuild = false
    @State private var isStartingRelease = Self.initialStartingRelease

    /// 撮影では、起動引数でリリースを始めるシートを開いておく
    private static var initialStartingRelease: Bool {
        #if DEBUG
        DemoLaunch.initialSheet() == .startRelease
        #else
        false
        #endif
    }

    var body: some View {
        if let repository = store.repository(repositoryID) {
            let epics = store.snapshot?.epics.filter { $0.repositoryID == repositoryID } ?? []
            let isRemoved = store.snapshot?.isRemoved(repositoryID) == true
            List {
                CardSection {
                    HStack(spacing: 14) {
                        AppIconView(repository: repository, size: 60)
                        VStack(alignment: .leading) {
                            Text(repository.appName).appFont(.title2, weight: .semibold)
                            OwnerLabel(repository: repository, avatarSize: 18)
                                .appFont(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if isRemoved {
                    RemovedRepositorySection(repositoryID: repositoryID)
                } else {
                    BuildSettingsSection(repository: repository, isEditing: $isEditingBuild)
                }
                CardSection("epic") {
                    ForEach(epics) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                    if epics.isEmpty {
                        Text("ありません").foregroundStyle(.secondary)
                    }
                }
                ReleaseSection(repository: repository, isRemoved: isRemoved, isStarting: $isStartingRelease)
            }
            .pastelBackground()
            .compactList()
            .navigationTitle(repository.appName)
            .sheet(isPresented: $isEditingBuild) {
                BuildSettingsSheet(repository: repository)
            }
            .sheet(isPresented: $isStartingRelease) {
                StartReleaseSheet(repository: repository) { isStartingRelease = false }
            }
            .toolbar {
                if !isRemoved {
                    RepositoryMenu(repositoryID: repositoryID, isConfirmingRemoval: $isConfirmingRemoval)
                }
            }
            .confirmationDialog("「\(repository.appName)」を対象から外しますか？", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
                Button("外す", role: .destructive) {
                    Task { await store.send(.removeRepository(repositoryID: repositoryID)) }
                }
            } message: {
                Text("GitHub のリポジトリと、AskHub の記録（終わった epic など）は消しません。外すと依頼できなくなります。「対象に加える」から戻すと、ビルドの設定などもそのまま戻ります")
            }
        } else {
            ContentUnavailableView("このリポジトリは見つかりません", systemImage: "questionmark.folder")
        }
    }
}

/// リポジトリの操作。進めている epic があるあいだは外せない（司令塔が断る）ので、押せなくしてわけを出す
private struct RepositoryMenu: ToolbarContent {
    let repositoryID: TargetRepository.ID
    @Binding var isConfirmingRemoval: Bool

    @Environment(ClientStore.self) private var store

    var body: some ToolbarContent {
        let canRemove = store.supports(.removeRepository(repositoryID: repositoryID))
        ToolbarItem(placement: .primaryAction) {
            Menu("操作", systemImage: "ellipsis.circle") {
                if canRemove {
                    Button("対象から外す…", systemImage: "folder.badge.minus", role: .destructive) { isConfirmingRemoval = true }
                } else {
                    Button("対象から外す（進めている epic があるあいだは外せません）", systemImage: "folder.badge.minus") {}
                        .disabled(true)
                }
            }
            // 前の操作（加える・外す）の同期を待つ間は押せなくする
            .disabled(store.isReflecting([.repository(repositoryID)]))
        }
    }
}

/// 外したリポジトリの案内と、加え直すボタン
private struct RemovedRepositorySection: View {
    let repositoryID: TargetRepository.ID

    @Environment(ClientStore.self) private var store

    var body: some View {
        CardSection {
            Label("対象から外しています", systemImage: "folder.badge.minus")
                .foregroundStyle(.secondary)
            Button("対象に加え直す", systemImage: "folder.badge.plus") {
                Task { await store.send(.addRepository(repositoryID: repositoryID)) }
            }
            .disabled(store.isReflecting([.repository(repositoryID)]))
        } footer: {
            Text("加え直すと、ビルドの設定などは外す前のまま戻ります")
        }
    }
}

/// 対象に加える。候補（まだ対象になっていないリポジトリ）があれば選び、無ければ owner/name を入れる
struct AddRepositorySheet: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: TargetRepository.ID?
    @State private var fullName = ""
    @State private var sending = SheetSendState()

    var body: some View {
        let allCandidates = store.snapshot?.candidateRepositories ?? []
        let removed = store.snapshot?.removedRepositories ?? []
        let candidates = allCandidates.filter {
            query.isEmpty || $0.fullName.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query)
        }
        NavigationStack {
            Form {
                if sending.showsStatus {
                    Section {
                        SheetSendStatus(state: sending) { submit() }
                    }
                }
                if allCandidates.isEmpty {
                    // 状態リポジトリにつないだときは、トークンが状態リポジトリしか見えないので候補を並べられない
                    Section {
                        TextField("owner/name", text: $fullName, prompt: Text("owner/name"))
                            .labelsHidden()
                            .autocorrectionDisabled()
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .onChange(of: fullName) { selectedID = Self.repositoryID(fullName) }
                    } header: {
                        Text("リポジトリ")
                    } footer: {
                        Text("例: shilokuma-inc/askhub-sandbox。司令塔が受け取ると、対象の一覧に出ます")
                    }
                } else {
                    Section("リポジトリ") {
                        Picker("リポジトリ", selection: $selectedID) {
                            Text("選んでください").tag(TargetRepository.ID?.none)
                            ForEach(candidates) { repository in
                                Text("\(repository.appName)（\(repository.fullName)）").tag(Optional(repository.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                }
                if !removed.isEmpty {
                    Section {
                        Picker("外したリポジトリ", selection: $selectedID) {
                            ForEach(removed) { repository in
                                Text("\(repository.appName)（\(repository.fullName)）").tag(Optional(repository.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("外したリポジトリを戻す")
                    } footer: {
                        Text("ビルドの設定などは、外す前のまま戻ります")
                    }
                }
            }
            .disabled(sending.isSending)
            .searchable(text: $query, prompt: "名前で探す")
            .formStyle(.grouped)
            .pastelBackground()
            .navigationTitle("対象に加える")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                        .disabled(sending.isSending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    SheetSendButton("加える", isSending: sending.isSending) { submit() }
                        .disabled(selectedID == nil)
                }
            }
        }
        .sheetSending(sending)
        .sheetSize(.form)
    }

    /// 送る。送り始めたら（同じものを送ってあったときも）すぐ閉じ、一覧は加えた形になる。送れなければ理由を出して残る
    private func submit() {
        guard let selectedID else {
            return
        }
        if sending.submit(.addRepository(repositoryID: selectedID), in: store) {
            dismiss()
        }
    }

    /// 入れた owner/name。形が違えば nil（送る前に止める）
    private static func repositoryID(_ text: String) -> TargetRepository.ID? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }
        return parts.joined(separator: "/")
    }
}

/// リポジトリのリリース。リリースを始めるボタン、進めている版（準備から配信まで）、配信した版の順に並べる
private struct ReleaseSection: View {
    let repository: TargetRepository
    let isRemoved: Bool
    @Binding var isStarting: Bool

    @Environment(ClientStore.self) private var store

    var body: some View {
        let releases = store.snapshot?.releases(of: repository.id) ?? []
        let submissions = (store.snapshot?.submissions(of: repository.id) ?? []).filter { !$0.isEnded }
        let suggested = store.snapshot?.suggestedReleaseVersion(of: repository.id) ?? "1.0.0"
        CardSection {
            // App Store に載せる準備（アプリが無い・初めての版の残りがある）。出さないリポジトリは、出すに戻せるように行を残す
            if let setup = store.snapshot?.appStoreSetup(of: repository.id), setup.releasedAt == nil, !isRemoved {
                NavigationLink(value: AppRoute.appStoreSetup(repository.id)) {
                    AppStoreSetupRow(setup: setup)
                }
                .accessibilityIdentifier("app-store-setup")
            }
            // 進めているリリースがあるあいだは始められない（司令塔が断る）ので出さない。わけは下の注記に出す
            if !isRemoved, submissions.isEmpty, store.supports(.startRelease(repositoryID: repository.id, version: suggested)) {
                Button("リリースを始める…", systemImage: "airplane.departure") { isStarting = true }
                    .accessibilityIdentifier("release-start")
            }
            ForEach(submissions) { submission in
                NavigationLink(value: AppRoute.submission(repositoryID: submission.repositoryID, version: submission.version)) {
                    SubmissionRow(submission: submission)
                }
            }
            ForEach(releases) { release in
                NavigationLink(value: AppRoute.release(repositoryID: release.repositoryID, version: release.version)) {
                    ReleaseRow(release: release)
                }
            }
            if releases.isEmpty && submissions.isEmpty {
                Text("App Store で配信した版はまだありません").foregroundStyle(.secondary)
            }
        } header: {
            Text("リリース")
        } footer: {
            Text(submissions.isEmpty
                ? "リリースを始めると、司令塔が release ブランチ・What's New・ビルドを用意し、あなたが確かめてから審査に出します"
                : "進めているリリースが終わると、次のリリースを始められます（App Store Connect の編集できる版は 1 つ）")
        }
    }
}

/// App Store に載せる準備の行（残りの数・出さない）
private struct AppStoreSetupRow: View {
    let setup: AppStoreSetup

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label("App Store の準備", systemImage: "checklist").appFont(.headline, weight: .semibold)
                ReflectionBadge([.appStore(setup.repositoryID)])
            }
            Text(detail).appFont(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var detail: String {
        if setup.isExcluded { return "App Store に出さない" }
        let remaining = setup.pendingItems(firstRelease: true).count
        if setup.app == nil { return "App Store Connect にアプリがありません" }
        return remaining == 0 ? "済み" : "残り \(remaining)"
    }
}

/// 進めている版の行（版・今の段取り）
private struct SubmissionRow: View {
    let submission: Submission

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(submission.version).appFont(.headline, weight: .semibold)
                Text(submission.startedInAskHub ? "リリース中" : "審査に出した版")
                    .foregroundStyle(.secondary)
                ReflectionBadge([.submission(repositoryID: submission.repositoryID, version: submission.version)])
            }
            Text(submission.summary)
                .appFont(.subheadline)
                .foregroundStyle(submission.needsHuman || submission.isRejected ? Theme.danger : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 配信した版の行（版・プラットフォーム・後作業の様子）
private struct ReleaseRow: View {
    let release: Release

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(release.version).appFont(.headline, weight: .semibold)
                Text(release.platformSummary)
                    .foregroundStyle(.secondary)
            }
            Text(summary)
                .appFont(.subheadline)
                .foregroundStyle(release.needsHuman ? Theme.danger : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var summary: String {
        if release.isFinished {
            return "後作業は済みました"
        }
        if let step = release.steps.first(where: { $0.state == .problem || $0.state == .waitingHuman }) {
            return "\(step.title): \(step.detail)"
        }
        let done = release.steps.filter { $0.state == .done }.count
        return "後作業を進めています（\(done)/\(release.steps.count)）"
    }
}
