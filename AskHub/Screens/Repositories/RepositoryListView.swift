import SwiftUI

/// 「リポジトリ」。対象のリポジトリ（AskHub でループ開発を回すもの）を、organization ごとの見出しを付けて並べる
struct RepositoryListView: View {
    let selection: Binding<AppRoute?>?

    @Environment(ClientStore.self) private var store
    @State private var isAdding = false

    var body: some View {
        let groups = store.snapshot?.repositoryGroups ?? []
        RouteList(selection: selection) {
            if let appKit = store.snapshot?.appKit {
                CardSection {
                    NavigationLink(value: AppRoute.appKit) {
                        AppKitRow(appKit: appKit)
                    }
                } header: {
                    Text("共通のワークフロー")
                }
            }
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

/// リポジトリの詳細。やること・リリース・epic を上に、ビルドの設定・保護・app-kit を下の「設定」にまとめる（ユーザーの決定。2026-11-24）。
/// 外したリポジトリは、加え直すボタンを出す
struct RepositoryDetailView: View {
    let repositoryID: TargetRepository.ID

    @Environment(ClientStore.self) private var store
    @State private var isConfirmingRemoval = false
    @State private var isEditingBuild = false
    @State private var isEditingProtection = false
    @State private var isStartingRelease = Self.initialStartingRelease

    /// やることから送る、同じ画面の「加えるときの準備」の節
    private static let setupSectionID = "repository-setup"

    /// 撮影では、起動引数でリリースを始めるシートを開いておく
    private static var initialStartingRelease: Bool {
        #if DEBUG
        DemoLaunch.initialSheet() == .startRelease
        #else
        false
        #endif
    }

    var body: some View {
        if let repository = store.repository(repositoryID), let snapshot = store.snapshot {
            let isRemoved = snapshot.isRemoved(repositoryID)
            let todos = RepositoryTodo.items(for: repository, inbox: store.inboxItems, snapshot: snapshot)
            ScrollViewReader { proxy in
                List {
                    RepositoryHeaderSection(repository: repository)
                    if isRemoved {
                        RemovedRepositorySection(repositoryID: repositoryID)
                    }
                    RepositoryTodoSection(items: todos) { perform($0, proxy: proxy) }
                    // App Store の準備の残りはやることに出すので、リリースには残りの無いとき（済み・出さない）だけ出す
                    ReleaseSection(
                        repository: repository,
                        isRemoved: isRemoved,
                        showsAppStoreSetup: !todos.contains { $0.action == .route(.appStoreSetup(repositoryID)) },
                        isStarting: $isStartingRelease
                    )
                    EpicSection(epics: snapshot.epics.filter { $0.repositoryID == repositoryID })
                    if !isRemoved {
                        CreativeRepositorySection(repository: repository)
                    }
                    settings(repository, isRemoved: isRemoved)
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle(repository.appName)
            .sheet(isPresented: $isEditingBuild) {
                BuildSettingsSheet(repository: repository)
            }
            .sheet(isPresented: $isEditingProtection) {
                if let protection = repository.protection {
                    ProtectionSheet(repository: repository, protection: protection)
                }
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

    /// 下の「設定」。ビルドの設定・加えるときの準備・保護・app-kit（外したリポジトリは、残っている準備と保護の様子だけ）
    @ViewBuilder private func settings(_ repository: TargetRepository, isRemoved: Bool) -> some View {
        let appKit = isRemoved ? nil : repository.appKit
        if !isRemoved || repository.setup != nil || repository.protection != nil {
            // 下の節をまとめる見出し。見出しだけの節なので、次の節との間を詰める（Mac の一覧にはセクションの間が無い）
            CardSection {} header: {
                Text("設定").appFont(.title3, weight: .bold).foregroundStyle(.primary)
            }
            #if os(iOS)
            .listSectionSpacing(4)
            #endif
        }
        if !isRemoved {
            BuildSettingsSection(repository: repository, isEditing: $isEditingBuild)
        }
        if let setup = repository.setup {
            RepositorySetupSection(repository: repository, setup: setup)
                .id(Self.setupSectionID)
        }
        if let protection = repository.protection {
            ProtectionSection(repository: repository, protection: protection, showsSheet: $isEditingProtection)
        }
        if let appKit {
            AppKitRepositorySection(repository: repository, appKit: appKit)
        }
    }

    /// やることの、画面を開かない行き先
    private func perform(_ action: RepositoryTodo.Action, proxy: ScrollViewProxy) {
        switch action {
        case .buildSettings: isEditingBuild = true
        case .protection: isEditingProtection = true
        case .setup: withAnimation { proxy.scrollTo(Self.setupSectionID, anchor: .top) }
        case .route: break
        }
    }
}

/// リポジトリの画面の一番上（アイコン・アプリ名・持ち主）。Mac・iPad の 3 列では画面の見出しが出ないので、アプリ名をここにも出す
private struct RepositoryHeaderSection: View {
    let repository: TargetRepository

    var body: some View {
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
    }
}

/// リポジトリの epic（進めているものと終わったもの）
private struct EpicSection: View {
    let epics: [Epic]

    var body: some View {
        CardSection("epic") {
            ForEach(epics) { epic in
                NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
            }
            if epics.isEmpty {
                Text("ありません").foregroundStyle(.secondary)
            }
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

/// リポジトリのリリース。リリースを始めるボタン、進めている版（準備から配信まで）、配信した版の順に並べる
private struct ReleaseSection: View {
    let repository: TargetRepository
    let isRemoved: Bool
    /// App Store に載せる準備の行を出す（残りがあるときは、上のやることに出す）
    let showsAppStoreSetup: Bool
    @Binding var isStarting: Bool

    @Environment(ClientStore.self) private var store

    var body: some View {
        let releases = store.snapshot?.releases(of: repository.id) ?? []
        let submissions = (store.snapshot?.submissions(of: repository.id) ?? []).filter { !$0.isEnded }
        let suggested = store.snapshot?.suggestedReleaseVersion(of: repository.id) ?? "1.0.0"
        CardSection {
            // App Store に載せる準備（アプリが無い・初めての版の残りがある）。出さないリポジトリは、出すに戻せるように行を残す
            if showsAppStoreSetup, let setup = store.snapshot?.appStoreSetup(of: repository.id), setup.releasedAt == nil, !isRemoved {
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
