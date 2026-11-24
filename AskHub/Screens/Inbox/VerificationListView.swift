import SwiftUI

/// 実機確認の一覧。マージした epic ごとの残りの数と、まとめての操作（まとめて確認した・確かめずに閉じる）を並べ、
/// アプリをまたいでスワイプで流す入口と、配信した版の確認（畳んだもの）を置く（2026-11-24 のユーザーの決定）。
///
/// まとめての操作は取り消しの猶予つきで送る（確かめずに閉じても、司令塔は確認の記録を消さないので、確かめるダイアログは出さない）
struct VerificationListView: View {
    @Environment(ClientStore.self) private var store
    @State private var showsFolded = Self.initialShowsFolded
    /// 確かめずに閉じる理由を書くシート（閉じる epic）
    @State private var closing: VerificationBacklog.Entry?
    /// 撮影用に、開いてすぐ理由のシートを出すか
    @State private var opensClosingSheet = Self.initialClosingSheet

    var body: some View {
        let backlog = store.snapshot.map(VerificationBacklog.init) ?? VerificationBacklog(open: [], folded: [])
        List {
            if !backlog.open.isEmpty {
                CardSection {
                    NavigationLink(value: AppRoute.deck(.allVerifications)) {
                        VerificationDeckRow(backlog: backlog)
                    }
                }
                // Mac・iPad の詳細の列には画面の名前が出ないので、見出しにも名前を入れる
                CardSection("実機で確かめるもの · \(backlog.open.count)") {
                    ForEach(backlog.open) { entry in
                        row(entry)
                    }
                }
            }
            if !backlog.folded.isEmpty {
                CardSection {
                    DisclosureGroup("配信した版の確認 · \(backlog.folded.count)", isExpanded: $showsFolded) {
                        ForEach(backlog.folded) { entry in
                            row(entry)
                        }
                    }
                } footer: {
                    Text(Self.foldedNote(backlog.folded, store: store))
                }
            }
        }
        .overlay {
            if backlog.isEmpty {
                ContentUnavailableView(
                    "確かめるものはありません",
                    systemImage: "iphone",
                    description: Text("最終 PR をマージした epic の実機確認が来たら、ここに並べます")
                )
            }
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("実機で確かめる")
        .toolbar {
            // まとめて答えて一覧から外した epic の様子（反映中・断られた）も出す
            ToolbarItem(placement: .primaryAction) {
                ReflectionBadge(Self.reflectionTargets(in: store))
            }
        }
        .sheet(item: $closing) { entry in
            TextRequestSheet(
                request: .closingVerifications(epicID: entry.id),
                subject: .init(closing: entry.epic, count: entry.items.count, appName: store.repository(entry.epic.repositoryID)?.appName),
                focusesOnAppear: Self.focusesTextOnAppear
            ) { text in
                closing = nil
                send(.closeVerifications(epicID: entry.id, reply: .skipped(note: text)), entry: entry)
            } onCancel: {
                closing = nil
            }
        }
        .onAppear {
            if opensClosingSheet {
                opensClosingSheet = false
                closing = backlog.open.first
            }
        }
    }

    /// epic の 1 行。押すとその epic の確認を 1 枚ずつ流し、スワイプ（Mac は右クリック）でまとめて答える
    private func row(_ entry: VerificationBacklog.Entry) -> some View {
        let confirm = HumanIntent.closeVerifications(epicID: entry.id, reply: .confirmed)
        let canClose = store.supports(confirm)
        return NavigationLink(value: AppRoute.deck(.verifications(entry.id))) {
            VerificationEpicRow(entry: entry)
        }
        // 行を消す前提の role（destructive）は付けない。シートを出すだけで行が残ると、一覧の差分で落ちる（LEARNINGS の SwiftUI）
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if canClose {
                Button("確かめずに閉じる…", systemImage: "xmark.circle") { closing = entry }
                    .tint(.gray)
                Button("まとめて確認した", systemImage: "checkmark.circle") { send(confirm, entry: entry) }
                    .tint(Theme.success)
            }
        }
        .contextMenu {
            if canClose {
                Button("残り \(entry.items.count) 件をまとめて確認した", systemImage: "checkmark.circle") { send(confirm, entry: entry) }
                Button("確かめずに閉じる…", systemImage: "xmark.circle") { closing = entry }
            }
        }
    }

    private func send(_ intent: HumanIntent, entry: VerificationBacklog.Entry) {
        let appName = store.repository(entry.epic.repositoryID)?.appName ?? entry.epic.repositoryID
        var action = "残り \(entry.items.count) 件をまとめて確認した"
        if case .closeVerifications(_, .skipped) = intent {
            action = "確かめずに閉じる"
        }
        withAnimation {
            store.enqueue(intent, message: "\(appName) · \(entry.epic.title): \(action)")
        }
    }

    /// 畳んだわけ（どのアプリのどの版を配信したか）
    private static func foldedNote(_ folded: [VerificationBacklog.Entry], store: ClientStore) -> String {
        var versions: [String] = []
        for entry in folded {
            guard let release = entry.foldedBy else {
                continue
            }
            let name = "\(store.repository(release.repositoryID)?.appName ?? release.repositoryID) \(release.version)"
            if !versions.contains(name) {
                versions.append(name)
            }
        }
        return "\(versions.joined(separator: "・")) を配信したので、それより前にマージした epic の残りの確認を畳みました。"
            + "あなたの番には数えません。開けば答える・閉じることもできます"
    }

    /// 一覧に出す（出していた）epic の、まとめての答えと項目ごとの答えの対象
    private static func reflectionTargets(in store: ClientStore) -> [IntentTarget] {
        (store.snapshot?.epics ?? []).flatMap { epic -> [IntentTarget] in
            guard let items = epic.finalReview?.verifications, !items.isEmpty else {
                return []
            }
            return [.verifications(epicID: epic.id)] + items.map { .verification(epicID: epic.id, itemID: $0.id) }
        }
    }

    /// 理由のシートを開いてすぐ、入力欄にフォーカスを当てるか（iOS は入力欄を押してからキーボードを出す。まとめて判断するのシートと同じ）
    private static var focusesTextOnAppear: Bool {
        #if os(iOS)
        false
        #else
        true
        #endif
    }

    private static var initialShowsFolded: Bool {
        #if DEBUG
        DemoLaunch.expandsFoldedVerifications()
        #else
        false
        #endif
    }

    private static var initialClosingSheet: Bool {
        #if DEBUG
        DemoLaunch.initialSheet() == .closeVerifications
        #else
        false
        #endif
    }
}

/// アプリをまたいでスワイプで流す入口。確かめるものの epic のアプリのアイコンを重ねて出す
private struct VerificationDeckRow: View {
    let backlog: VerificationBacklog

    @Environment(ClientStore.self) private var store

    var body: some View {
        let repositories = backlog.open
            .compactMap { store.repository($0.epic.repositoryID) }
            .reduce(into: [TargetRepository]()) { result, item in
                if !result.contains(item) {
                    result.append(item)
                }
            }
        HStack(spacing: 12) {
            HStack(spacing: -10) {
                ForEach(repositories.prefix(4)) { repository in
                    AppIconView(repository: repository, size: 30)
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(.background, lineWidth: 2))
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("まとめてスワイプで答える")
                    .rowFont(.title)
                Text("\(backlog.open.count) 件の epic · \(backlog.openItemCount) 項目を、アプリをまたいで")
                    .rowFont(.subtitle)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "rectangle.stack.fill")
                .foregroundStyle(.tint)
        }
        .compactRow()
    }
}

/// epic の 1 行（アプリ・epic の題・残りの数とマージした時刻）
private struct VerificationEpicRow: View {
    let entry: VerificationBacklog.Entry

    @Environment(ClientStore.self) private var store

    var body: some View {
        let repository = store.repository(entry.epic.repositoryID)
        HStack(alignment: .top, spacing: 12) {
            AppIconView(repository: repository, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(repository?.appName ?? entry.epic.repositoryID)
                        .rowFont(.subtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    // まとめて・1 項目ずつ送った答えが反映を待っているか、断られた
                    ReflectionBadge(entry.targets)
                }
                Text(entry.epic.title)
                    .rowFont(.title)
                    .lineLimit(2)
                Text(detail)
                    .rowFont(.detail)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .compactRow()
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let count = "\(entry.items.count) 項目"
        guard let mergedAt = entry.mergedAt else {
            return count
        }
        return "\(count) · \(RelativeTime.string(mergedAt, now: store.currentDate()))にマージ"
    }
}
