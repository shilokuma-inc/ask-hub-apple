import SwiftUI

/// Mac の詳細（状態・容量・ジョブ・自己診断・片付けの候補）
struct MacDetailView: View {
    let macID: Mac.ID

    @Environment(ClientStore.self) private var store

    var body: some View {
        if let mac = store.mac(macID) {
            List {
                Section {
                    MacRow(mac: mac)
                    LabeledContent("機種", value: mac.model)
                    LabeledContent("動き方", value: residency(mac.residency))
                    LabeledContent("版", value: mac.version + (mac.versionMatches ? "" : "（司令塔と合いません）"))
                }
                Section("持っているジョブ") {
                    if mac.jobs.isEmpty {
                        Text("ありません").foregroundStyle(.secondary)
                    }
                    ForEach(mac.jobs) { job in
                        if let epicID = job.epicID {
                            NavigationLink(value: AppRoute.epic(epicID)) { jobRow(job) }
                        } else {
                            jobRow(job)
                        }
                    }
                }
                Section("起動したときの自己診断") {
                    ForEach(mac.selfChecks) { check in
                        LabeledContent {
                            Text(check.detail)
                        } label: {
                            Label(check.name, systemImage: check.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.isOK ? Color.primary : Theme.warning)
                        }
                    }
                }
                Section {
                    NavigationLink(value: AppRoute.cleanup(mac.id)) {
                        LabeledContent("片付けの候補", value: "\(mac.cleanupCandidates.count) 件")
                    }
                } footer: {
                    Text("ワーカーが作ったもの（作業場所・Simulator・DerivedData）は、マージの後に自動で片付けます。ここには手で作ったものだけを出します")
                }
            }
            .pastelBackground()
            .navigationTitle(mac.name)
        } else {
            ContentUnavailableView("この Mac は見つかりません", systemImage: "laptopcomputer.slash")
        }
    }

    private func jobRow(_ job: Mac.Job) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job.title)
            Text("\(RelativeTime.string(job.startedAt, now: store.currentDate()))から")
                .appFont(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func residency(_ residency: Mac.Residency) -> String {
        switch residency {
        case .always: "常時オン（常駐）"
        case .whileOpen: "開いている間だけ（常駐）"
        case .manual: "ターミナルで起動（常駐できない）"
        }
    }
}

/// 片付けの候補。選んだものだけを消す
struct CleanupView: View {
    let macID: Mac.ID

    @Environment(ClientStore.self) private var store
    @State private var selectedIDs: Set<CleanupCandidate.ID> = []
    @State private var isConfirming = false

    var body: some View {
        let candidates = store.mac(macID)?.cleanupCandidates ?? []
        let selectedBytes = candidates.filter { selectedIDs.contains($0.id) }.reduce(Int64(0)) { $0 + $1.bytes }
        List {
            Section {
                ForEach(candidates) { candidate in
                    Toggle(isOn: binding(for: candidate.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(candidate.name, systemImage: symbol(candidate.kind))
                            Text(ByteFormat.string(candidate.bytes))
                                .appFont(.caption)
                                .foregroundStyle(.secondary)
                            if let caution = candidate.caution {
                                Label(caution, systemImage: "exclamationmark.triangle.fill")
                                    .appFont(.caption)
                                    .foregroundStyle(Theme.warning)
                            }
                        }
                    }
                }
            } footer: {
                Text("消す前に、未コミット・未 push・stash が無いかを確かめます")
            }
        }
        .overlay {
            if candidates.isEmpty {
                ContentUnavailableView("片付けの候補はありません", systemImage: "sparkles")
            }
        }
        .pastelBackground()
        .navigationTitle("片付けの候補")
        .safeAreaBar(edge: .bottom) {
            if !candidates.isEmpty {
                Button("選んだものを消す（\(ByteFormat.string(selectedBytes))）", role: .destructive) { isConfirming = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(selectedIDs.isEmpty)
                    .padding(.vertical, 10)
                    .keepsControlSize()
            }
        }
        .confirmationDialog("\(selectedIDs.count) 件を消しますか？", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                let ids = Array(selectedIDs)
                selectedIDs = []
                Task { await store.send(.cleanUp(macID: macID, candidateIDs: ids)) }
            }
        } message: {
            Text("合計 \(ByteFormat.string(selectedBytes)) を消します。元に戻せません")
        }
    }

    private func binding(for id: CleanupCandidate.ID) -> Binding<Bool> {
        Binding {
            selectedIDs.contains(id)
        } set: { isOn in
            if isOn {
                selectedIDs.insert(id)
            } else {
                selectedIDs.remove(id)
            }
        }
    }

    private func symbol(_ kind: CleanupCandidate.Kind) -> String {
        switch kind {
        case .clone: "folder"
        case .simulator: "iphone"
        case .derivedData: "hammer"
        }
    }
}
