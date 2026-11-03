import SwiftUI

/// 「リポジトリ」。対象のリポジトリ（AskHub でループ開発を回すもの）を並べる
struct RepositoryListView: View {
    let selection: Binding<AppRoute?>?

    @Environment(ClientStore.self) private var store
    @State private var isAdding = false

    var body: some View {
        let repositories = store.snapshot?.repositories ?? []
        RouteList(selection: selection) {
            Section {
                ForEach(repositories) { repository in
                    NavigationLink(value: AppRoute.repository(repository.id)) {
                        RepositoryRow(repository: repository)
                    }
                }
            } footer: {
                Text("対象に加えても、どの Mac にも clone しません。ジョブが要るときに、その Mac でだけ取り寄せます")
            }
        }
        .overlay {
            LoadStateOverlay(
                isEmpty: repositories.isEmpty,
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
                Text(repository.appName).appFont(.headline)
                Text(repository.fullName)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                if let active {
                    Text(active.title)
                        .appFont(.footnote)
                        .foregroundStyle(.tint)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
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
                Section {
                    HStack(spacing: 14) {
                        AppIconView(repository: repository, size: 60)
                        VStack(alignment: .leading) {
                            Text(repository.appName).appFont(.title2, weight: .semibold)
                            Text(repository.fullName).appFont(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("epic") {
                    ForEach(epics) { epic in
                        NavigationLink(value: AppRoute.epic(epic.id)) { EpicRow(epic: epic) }
                    }
                    if epics.isEmpty {
                        Text("ありません").foregroundStyle(.secondary)
                    }
                }
                Section {
                    Label("リリースの画面は、リリースの段階で作ります", systemImage: "shippingbox")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("リリース")
                }
            }
            .pastelBackground()
            .navigationTitle(repository.appName)
        } else {
            ContentUnavailableView("このリポジトリは見つかりません", systemImage: "questionmark.folder")
        }
    }
}

/// 対象に加える。まだ対象になっていないリポジトリだけを出す
struct AddRepositorySheet: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selectedID: TargetRepository.ID?

    var body: some View {
        let candidates = (store.snapshot?.candidateRepositories ?? []).filter {
            query.isEmpty || $0.fullName.localizedCaseInsensitiveContains(query) || $0.appName.localizedCaseInsensitiveContains(query)
        }
        NavigationStack {
            Form {
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
            .searchable(text: $query, prompt: "名前で探す")
            .pastelBackground()
            .navigationTitle("対象に加える")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("加える") {
                        guard let selectedID else {
                            return
                        }
                        Task {
                            await store.send(.addRepository(repositoryID: selectedID))
                            dismiss()
                        }
                    }
                    .disabled(selectedID == nil)
                }
            }
        }
    }
}
