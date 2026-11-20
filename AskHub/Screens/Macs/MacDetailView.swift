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
                    LabeledContent("版", value: mac.version + (mac.commanderVersion.map { "（司令塔は \($0)）" } ?? ""))
                    LabeledContent("互換の番号", value: mac.compatibility.map(String.init) ?? "分かりません")
                    claudeVersionRow(mac)
                    LabeledContent("Xcode", value: mac.xcodeVersion ?? "分かりません")
                }
                if let incompatibility = mac.incompatibility {
                    updateSection(mac, incompatibility: incompatibility)
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
                    Text(tokenFooter(mac))
                }
                if let quota = mac.githubQuota, quota.isCurrent(now: store.currentDate()) {
                    quotaSection(quota)
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

    /// 司令塔と互換の番号が合わないときの、更新の手順。版が違うだけ（互換の番号が合う）なら出さない
    private func updateSection(_ mac: Mac, incompatibility: Mac.Incompatibility) -> some View {
        CardSection {
            Label(mac.compatibilityText, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(mac.updateStep)
                if let command = mac.updateCommand {
                    Text(command)
                        .appFont(.caption)
                        .monospaced()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            if let message = incompatibility.message {
                Text(message)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(mac.comparesCompatibility ? (mac.updatesCommander ? "司令塔の更新" : "ワーカーの更新") : "互換の番号の確認")
        } footer: {
            Text("互換の番号が合うまで、この Mac は新しいジョブを引き受けません。持っているジョブは最後まで動かします")
        }
    }

    /// GitHub の REST の上限の残り（この Mac が生きている印を書くときに読んだもの）。少なければ警告の色にする
    private func quotaSection(_ quota: GitHubQuota) -> some View {
        CardSection {
            LabeledContent("残り", value: "\(GitHubQuota.count(quota.remaining)) / \(GitHubQuota.count(quota.limit)) 回")
                .foregroundStyle(quota.isLow(now: store.currentDate()) ? Theme.warning : Color.primary)
            LabeledContent("戻る時刻", value: RelativeTime.clock(quota.resetAt))
        } header: {
            Text("GitHub の上限")
        } footer: {
            Text("\(RelativeTime.clock(quota.checkedAt)) にこの Mac が読んだ値です。1 時間の回数を、アプリ・司令塔・Claude のセッションの gh が分け合います")
        }
    }

    /// 司令塔と版が違えば、司令塔の版を添える（そろえるのは、その Mac の設定の claude の場所に同じ版を入れる）
    private func claudeVersionRow(_ mac: Mac) -> some View {
        let commander = mac.commanderClaudeVersion.map { "（司令塔は \($0)）" } ?? ""
        return LabeledContent("Claude Code", value: (mac.claudeVersion ?? "分かりません") + commander)
    }

    /// 入れ直し方。管理用のトークンを置いた Mac（司令塔）は、その使い道も添える
    private func tokenFooter(_ mac: Mac) -> String {
        let renewal = "期限まで 14 日を切ったら、この Mac の端末でコマンドを流して入れ直します。GitHub のトークンは作り直してから、Claude のトークンは claude setup-token で作ってから貼ります"
        guard mac.tokens.contains(where: { !$0.stopsWork }) else {
            return renewal
        }
        return renewal + "。管理用のトークンは、保護の設定と対象に加えるときの準備にだけ使います。切れてもほかの仕事は止まりません"
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

/// 片付けの候補。「探す」を押すとその Mac のワーカーが探し、選んだものだけを消す
struct CleanupView: View {
    let macID: Mac.ID

    @Environment(ClientStore.self) private var store
    @State private var selectedIDs: Set<CleanupCandidate.ID> = []
    @State private var isConfirming = false

    var body: some View {
        let mac = store.mac(macID)
        let candidates = mac?.cleanupCandidates ?? []
        // 選んだ後に注意が付いた（消せなくなった）候補は、選んだ数にも送るものにも入れない
        let chosen = candidates.filter { selectedIDs.contains($0.id) && $0.caution == nil }
        let selectedBytes = chosen.reduce(Int64(0)) { $0 + $1.bytes }
        List {
            if let mac {
                statusSection(mac)
            }
            CardSection {
                if candidates.isEmpty, mac?.cleanupWork == .unknown {
                    Text("片付けの状態を読めませんでした").foregroundStyle(.secondary)
                } else if candidates.isEmpty {
                    Text(mac?.cleanupScannedAt == nil
                        ? "まだ探していません。「探す」を押すと、この Mac のワーカーが、手で作った clone・Simulator・DerivedData を探します"
                        : "片付けの候補はありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { candidate in
                    candidateRow(candidate)
                }
            } footer: {
                if !candidates.isEmpty {
                    Text("未コミット・未 push・stash などがあるものは選べません。消すときにも、もう一度確かめます")
                }
            }
        }
        // 探し直したら、前の一覧で選んだものは消す（同じ id でも、注意の付き方が変わっているかもしれない）
        .onChange(of: mac?.cleanupScannedAt) {
            selectedIDs = []
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("片付けの候補")
        .safeAreaBar(edge: .bottom) {
            // 片付けを送ったら、司令塔が受け付けてワーカーが済ませるまで押せなくする（断られた理由などは残す）
            cleanupBar(candidates: candidates, chosen: chosen, selectedBytes: selectedBytes)
        }
        .confirmationDialog("\(selectedIDs.count) 件を消しますか？", isPresented: $isConfirming, titleVisibility: .visible) {
            Button("消す", role: .destructive) {
                let ids = chosen.map(\.id)
                selectedIDs = []
                // ダイアログを開いている間に状態が分からなくなったら送らない（送る側でも断る）
                guard store.mac(macID)?.cleanupWork != .unknown else { return }
                Task { await store.send(.cleanUp(macID: macID, candidateIDs: ids)) }
            }
        } message: {
            Text(Self.confirmation(chosen, bytes: selectedBytes))
        }
    }

    /// 消す前の確かめの文。ゴミ箱に移すもの（clone・DerivedData）と、元に戻せないもの（Simulator）を分けて書く
    static func confirmation(_ selected: [CleanupCandidate], bytes: Int64) -> String {
        var lines = ["合計 \(ByteFormat.string(bytes)) を消します。"]
        if selected.contains(where: { $0.kind != .simulator }) {
            lines.append("clone と DerivedData はゴミ箱に移します（ゴミ箱を空にするまで空き容量は増えません）。")
        }
        if selected.contains(where: { $0.kind == .simulator }) {
            lines.append("Simulator は元に戻せません。")
        }
        return lines.joined(separator: "\n")
    }

    /// 最後に探した時刻・探している途中・読めなかった場所・最後の結果
    private func statusSection(_ mac: Mac) -> some View {
        CardSection {
            switch mac.cleanupWork {
            case .finding?:
                Label("探しています。数分かかることがあります", systemImage: "magnifyingglass")
                Text("しばらくたっても終わらないときは、この Mac のワーカー（常時オンの Mac は司令塔）が、片付けの候補に対応した版か確かめてください")
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            case .removing?:
                Label("消しています", systemImage: "trash")
            case .unknown?:
                Label("片付けの状態を読めませんでした。読み直すまで、探す・消すは送れません", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            case nil:
                LabeledContent("最後に探した時刻") {
                    Text(mac.cleanupScannedAt.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "まだ探していません")
                }
            }
            if let result = mac.cleanupResult {
                Text(result)
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
            }
            if !mac.cleanupUnreadable.isEmpty {
                Label("読めなかった場所: \(mac.cleanupUnreadable.joined(separator: "・"))", systemImage: "exclamationmark.triangle.fill")
                    .appFont(.caption)
                    .foregroundStyle(Theme.warning)
            }
        } footer: {
            if !mac.cleanupUnreadable.isEmpty {
                Text("デスクトップ・書類などを探すには、この Mac のシステム設定の「プライバシーとセキュリティ」で、ワーカー（常時オンの Mac は司令塔）にファイルとフォルダへのアクセスを許可します")
            }
        }
    }

    private func candidateRow(_ candidate: CleanupCandidate) -> some View {
        Toggle(isOn: binding(for: candidate.id)) {
            VStack(alignment: .leading, spacing: 2) {
                Label(candidate.name, systemImage: symbol(candidate.kind))
                Text(detail(of: candidate))
                    .appFont(.caption)
                    .foregroundStyle(.secondary)
                if let caution = candidate.caution {
                    Label(caution, systemImage: "exclamationmark.triangle.fill")
                        .appFont(.caption)
                        .foregroundStyle(Theme.warning)
                }
            }
        }
        // 消さない理由のあるものは選べない（ワーカーも消さない）
        .disabled(candidate.caution != nil)
    }

    /// 例: 2.1 GB · 最後に使った日 2026/09/01
    private func detail(of candidate: CleanupCandidate) -> String {
        let used = candidate.lastUsedAt.map { " · 最後に使った日 \($0.formatted(date: .numeric, time: .omitted))" } ?? ""
        return ByteFormat.string(candidate.bytes) + used
    }

    private func cleanupBar(candidates: [CleanupCandidate], chosen: [CleanupCandidate], selectedBytes: Int64) -> some View {
        let busy = store.isReflecting([.cleanup(macID: macID)]) || store.mac(macID)?.cleanupWork != nil
        return VStack(spacing: 6) {
            HStack {
                Button("探す") {
                    selectedIDs = []
                    Task { await store.send(.findCleanupCandidates(macID: macID)) }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .disabled(busy)
                if !candidates.isEmpty {
                    Button("選んだものを消す（\(ByteFormat.string(selectedBytes))）", role: .destructive) { isConfirming = true }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(chosen.isEmpty || busy)
                }
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
