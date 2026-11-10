import SwiftUI

/// Mac の詳細（状態・容量・ジョブ・自己診断・片付けの候補）
struct MacDetailView: View {
    let macID: Mac.ID

    @Environment(ClientStore.self) private var store

    var body: some View {
        if let mac = store.mac(macID) {
            List {
                CardSection {
                    MacRow(mac: mac)
                    if !mac.model.isEmpty {
                        LabeledContent("機種", value: mac.model)
                    }
                    LabeledContent("動き方", value: residency(mac.residency))
                    LabeledContent("版", value: mac.version + (mac.versionMatches ? "" : "（司令塔と合いません）"))
                    claudeVersionRow(mac)
                    LabeledContent("Xcode", value: mac.xcodeVersion ?? "分かりません")
                }
                CardSection("持っているジョブ") {
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
                CardSection {
                    ForEach(mac.tokens) { token in
                        tokenRow(token, mac: mac)
                    }
                } header: {
                    Text("トークン")
                } footer: {
                    Text("期限まで 14 日を切ったら、この Mac の端末でコマンドを流して入れ直します。GitHub のトークンは作り直してから、Claude のトークンは claude setup-token で作ってから貼ります")
                }
                CardSection("自己診断") {
                    ForEach(mac.selfChecks) { check in
                        LabeledContent {
                            Text(check.detail)
                        } label: {
                            Label(check.name, systemImage: check.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                .foregroundStyle(check.isOK ? Color.primary : Theme.warning)
                        }
                    }
                }
                CardSection {
                    NavigationLink(value: AppRoute.cleanup(mac.id)) {
                        LabeledContent("片付けの候補", value: "\(mac.cleanupCandidates.count) 件")
                    }
                } footer: {
                    Text("ワーカーが作ったもの（作業場所・Simulator・DerivedData）は、マージの後に自動で片付けます。ここには手で作ったものだけを出します")
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle(mac.name)
        } else {
            ContentUnavailableView("この Mac は見つかりません", systemImage: "laptopcomputer.slash")
        }
    }

    /// 司令塔と版が違えば、司令塔の版を添える（そろえるのは、その Mac の設定の claude の場所に同じ版を入れる）
    private func claudeVersionRow(_ mac: Mac) -> some View {
        let commander = mac.commanderClaudeVersion.map { "（司令塔は \($0)）" } ?? ""
        return LabeledContent("Claude Code", value: (mac.claudeVersion ?? "分かりません") + commander)
    }

    /// トークンの期限。入れ直すときは、Mac の端末で流すコマンドを出す
    private func tokenRow(_ token: MacToken, mac: Mac) -> some View {
        let status = token.status(now: store.currentDate())
        let needsRenewal = !isFine(status)
        return VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                Text(token.detail(now: store.currentDate()))
            } label: {
                Label(token.name, systemImage: needsRenewal ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(needsRenewal ? Theme.warning : Color.primary)
            }
            if needsRenewal {
                Text(mac.renewalCommand(for: token))
                    .appFont(.caption)
                    .monospaced()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func isFine(_ status: MacToken.Status) -> Bool {
        if case .ok = status {
            return true
        }
        return false
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
            CardSection {
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
        .compactList()
        .navigationTitle("片付けの候補")
        .safeAreaBar(edge: .bottom) {
            // 片付けを送ったら、司令塔が受け付けるまで押せなくする（送った結果を先に当てて候補が無くなっても、断られた理由などは残す）
            if !candidates.isEmpty || store.needsAttention([.cleanup(macID: macID)]) {
                cleanupBar(candidates: candidates, selectedBytes: selectedBytes)
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

    private func cleanupBar(candidates: [CleanupCandidate], selectedBytes: Int64) -> some View {
        VStack(spacing: 6) {
            if !candidates.isEmpty {
                Button("選んだものを消す（\(ByteFormat.string(selectedBytes))）", role: .destructive) { isConfirming = true }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .disabled(selectedIDs.isEmpty || store.isReflecting([.cleanup(macID: macID)]))
            }
            ReflectionStatusView(.cleanup(macID: macID), showsSyncBadge: true)
                .frame(maxWidth: 520)
                .padding(.horizontal)
        }
        .padding(.vertical, 10)
        .keepsControlSize()
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
