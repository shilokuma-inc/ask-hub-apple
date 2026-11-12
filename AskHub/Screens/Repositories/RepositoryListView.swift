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

/// リポジトリの詳細（進めている epic・リリース）
struct RepositoryDetailView: View {
    let repositoryID: TargetRepository.ID

    @Environment(ClientStore.self) private var store

    var body: some View {
        if let repository = store.repository(repositoryID) {
            let epics = store.snapshot?.epics.filter { $0.repositoryID == repositoryID } ?? []
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
                CardSection("epic") {
                    ForEach(epics) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                    if epics.isEmpty {
                        Text("ありません").foregroundStyle(.secondary)
                    }
                }
                CardSection {
                    let releases = store.snapshot?.releases(of: repositoryID) ?? []
                    ForEach(releases) { release in
                        NavigationLink(value: AppRoute.release(repositoryID: release.repositoryID, version: release.version)) {
                            ReleaseRow(release: release)
                        }
                    }
                    if releases.isEmpty {
                        Text("App Store で配信した版はまだありません").foregroundStyle(.secondary)
                    }
                } header: {
                    Text("リリース")
                } footer: {
                    Text("App Store で配信すると、司令塔が見つけて、タグ・GitHub Release・次の版の PR を作ります")
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle(repository.appName)
        } else {
            ContentUnavailableView("このリポジトリは見つかりません", systemImage: "questionmark.folder")
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
