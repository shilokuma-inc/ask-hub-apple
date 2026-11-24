import AskHubKit
import SwiftUI

/// リポジトリのタブの一番上の「app-kit」の行。新しい版・広げている途中・止まったことを一目で出す
struct AppKitRow: View {
    let appKit: AppKitOverview

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 20))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Theme.Tone.lavender.gradient, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("app-kit").rowFont(.title)
                    ReflectionBadge([.appKit])
                }
                Text(summary)
                    .rowFont(.subtitle)
                    .foregroundStyle(isAttention ? Theme.warning : Color.secondary)
                    .lineLimit(2)
            }
        }
        .compactRow()
    }

    private var isAttention: Bool {
        appKit.rollout?.state == .failed || appKit.problem != nil
    }

    private var summary: String {
        if let rollout = appKit.rollout {
            switch rollout.state {
            case .running:
                return "\(rollout.version) を広げています（\(rollout.doneCount) 本に入れた）"
            case .failed:
                return "\(rollout.version) を広げる途中で止まりました"
            case .finished, .stopped:
                break
            }
        }
        if let release = appKit.newRelease {
            return "\(release.version) が出ました"
        }
        return appKit.latest.map { "最新は \($0.version)" } ?? "版をまだ見つけていません"
    }
}

/// 「app-kit」の画面。新しい版の「広げる」と変更点、広げている進み具合（もう一度試す・やめる）、リポジトリとテンプレートごとの版、前の版
struct AppKitView: View {
    @Environment(ClientStore.self) private var store
    @Environment(\.openURL) private var openURL
    /// 確かめを開いたときの版。開いた後に版の一覧が変わっても、見たものだけを広げる
    @State private var confirming: AppKitOverview.Release?
    @State private var confirmsStop = false

    var body: some View {
        if let appKit = store.snapshot?.appKit {
            List {
                if let release = appKit.newRelease ?? appKit.latest {
                    ReleaseSection(
                        release: release, appKit: appKit, isNew: appKit.newRelease != nil, confirming: $confirming
                    )
                }
                if let rollout = appKit.rollout {
                    RolloutSection(rollout: rollout, appKit: appKit, confirming: $confirming, confirmsStop: $confirmsStop)
                }
                InstalledSection(appKit: appKit)
                if appKit.releases.count > 1 {
                    PreviousReleasesSection(appKit: appKit, confirming: $confirming)
                }
                if let rejection = appKit.rejection {
                    CardSection {
                        Label(rejection, systemImage: "xmark.octagon.fill").foregroundStyle(Theme.warning)
                    }
                }
            }
            .pastelBackground()
            .compactList()
            .navigationTitle("app-kit")
            .confirmationDialog(
                "app-kit を広げますか？",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                titleVisibility: .visible,
                presenting: confirming
            ) { release in
                Button("\(release.version) を広げる") {
                    Task { await store.send(.rolloutAppKit(version: release.version, ref: release.ref)) }
                }
            } message: { release in
                let pilot = appKit.rollout?.pilot ?? "試しの 1 本"
                Text(
                    "\(release.version) の写すファイルに置き換える PR を、\(pilot) → 残りのリポジトリ → テンプレートの順に 1 本ずつ出し、"
                        + "待つチェックが通ったら司令塔がマージします。試しの 1 本はマージした後の develop の Build を待ち、失敗したら止めます"
                )
            }
            .confirmationDialog(
                "広げるのをやめますか？", isPresented: $confirmsStop, titleVisibility: .visible, presenting: appKit.rollout
            ) { rollout in
                Button("やめて PR を閉じる", role: .destructive) {
                    Task { await store.send(.stopAppKitRollout(version: rollout.version, ref: rollout.ref)) }
                }
            } message: { rollout in
                Text("\(rollout.version) で開いている PR を司令塔が閉じ、残りには出しません。マージ済みのものは戻しません（戻すときは前の版を広げます）")
            }
        } else {
            ContentUnavailableView("司令塔がまだ app-kit の版を読んでいません", systemImage: "shippingbox")
        }
    }
}

/// 新しい版（無ければ一番新しい版）の「広げる」と変更点。広げる操作と PR を出す相手の数を先に出し、長い変更点は閉じておく
/// （変更点が 2 画面あると、広げる操作がその下に隠れた。ユーザーの決定。2026-11-24）
private struct ReleaseSection: View {
    let release: AppKitOverview.Release
    let appKit: AppKitOverview
    let isNew: Bool
    @Binding var confirming: AppKitOverview.Release?

    @Environment(ClientStore.self) private var store
    /// 変更点を開いているか。nil なら変更点の長さで決める（長ければ閉じておく）
    @State private var showsChanges: Bool?

    var body: some View {
        let intent = HumanIntent.rolloutAppKit(version: release.version, ref: release.ref)
        CardSection {
            LabeledContent(release.version) {
                Text(RelativeTime.string(release.foundAt, now: store.currentDate()) + "に出ました").foregroundStyle(.secondary)
            }
            if isNew || appKit.rollout?.version != release.version {
                if store.supports(intent) {
                    Button { confirming = release } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(release.version) を広げる…")
                                // ボタンの色を付けず、注記の灰色にする
                                Text(rolloutSummary).appFont(.caption).foregroundStyle(Color.secondary)
                            }
                        } icon: {
                            Image(systemName: "shippingbox.and.arrow.backward")
                        }
                    }
                    .disabled(store.isReflecting([.appKit]))
                } else if !appKit.canRollOut(release) {
                    Text("ほかの版を広げている途中です。やめてから広げます").appFont(.caption).foregroundStyle(.secondary)
                }
            }
            if let changes = release.changes {
                let isExpanded = Binding { showsChanges ?? !Self.isLong(changes) } set: { showsChanges = $0 }
                DisclosureGroup("変更点", isExpanded: isExpanded) {
                    RenderedBodyView(content: RenderedBody(body: changes))
                        .appFont(.callout)
                }
            } else {
                Text("CHANGELOG に変更点がありません").foregroundStyle(.secondary)
            }
        } header: {
            Text(isNew ? "新しい版" : "一番新しい版")
        } footer: {
            footer
        }
    }

    /// 広げると PR を出す相手の数
    private var rolloutSummary: String {
        let count = store.snapshot?.appKitRolloutCount(release) ?? 0
        return count > 0
            ? "入れ替え済みの \(count) 本（古い版・ずれのあるもの）に、1 本ずつ PR を出します。major の違う相手には出しません"
            : "PR を出す相手はありません（入れ替え済みの相手は、この版が入っているか major が違います）"
    }

    /// 変更点が長い（7 行から。閉じておく）
    static func isLong(_ changes: String) -> Bool {
        changes.split(whereSeparator: \.isNewline).count > 6
    }

    private var footer: Text {
        var parts: [String] = []
        if let checkedAt = appKit.checkedAt {
            parts.append("\(RelativeTime.string(checkedAt, now: store.currentDate()))に司令塔がタグを読みました")
        }
        if let problem = appKit.problem {
            parts.append("最後に読めなかった理由: \(problem)")
        }
        if let adoption = appKit.adoptionVersion {
            parts.append("対象に加えるときの入れ替えには \(adoption) を使います")
        }
        return Text(parts.joined(separator: "。"))
    }
}

/// 広げている・最後に広げた版の進み具合
private struct RolloutSection: View {
    let rollout: AppKitOverview.Rollout
    let appKit: AppKitOverview
    @Binding var confirming: AppKitOverview.Release?
    @Binding var confirmsStop: Bool

    @Environment(ClientStore.self) private var store
    @Environment(\.openURL) private var openURL

    var body: some View {
        let reflecting = store.isReflecting([.appKit])
        CardSection {
            LabeledContent("様子") {
                Text(stateText).foregroundStyle(rollout.state == .failed ? Theme.warning : Color.secondary)
            }
            if let problem = rollout.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            ForEach(rollout.targets) { target in
                TargetRow(target: target, isPilot: target.repository == rollout.pilot)
            }
            if rollout.targets.isEmpty {
                Text("まだ相手を確かめていません").foregroundStyle(.secondary)
            }
            if let release = appKit.releases.first(where: { $0.version == rollout.version }),
               store.supports(.rolloutAppKit(version: release.version, ref: release.ref)) {
                Button(rollout.state == .failed ? "もう一度試す…" : "もう一度広げる（ずれを直す）…", systemImage: "arrow.clockwise") {
                    confirming = release
                }
                .disabled(reflecting)
            }
            if store.supports(.stopAppKitRollout(version: rollout.version, ref: rollout.ref)) {
                Button("やめる…", systemImage: "stop.circle", role: .destructive) { confirmsStop = true }
                    .disabled(reflecting)
            }
        } header: {
            Text("\(rollout.version) を広げる")
        } footer: {
            Text("試しの 1 本は \(rollout.pilot)。PR は一度に 1 本ずつ出します。写すファイルのほかが変わった PR はマージしません")
        }
    }

    private var stateText: String {
        let started = RelativeTime.string(rollout.startedAt, now: store.currentDate())
        return switch rollout.state {
        case .running: "広げています（\(started)に始めた）"
        case .failed: "止まりました"
        case .finished: "広げ終わりました"
        case .stopped: "やめました"
        }
    }
}

/// 版を広げる相手 1 つの行
private struct TargetRow: View {
    let target: AppKitOverview.Target
    let isPilot: Bool

    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Label(target.repository, systemImage: target.isTemplate ? "doc.on.doc" : "folder")
                    .rowFont(.subtitle)
                    .lineLimit(1)
                if isPilot {
                    Text("試しの 1 本").appFont(.caption2, weight: .semibold).foregroundStyle(.tint)
                }
                Spacer()
                Text(stateText).appFont(.caption).foregroundStyle(isProblem ? Theme.warning : Color.secondary)
            }
            if let problem = target.problem {
                Text(problem).appFont(.caption).foregroundStyle(isProblem ? Theme.warning : Color.secondary)
            }
            if let number = target.pullRequest, let url = target.pullRequestURL {
                Button("PR #\(number) を GitHub で見る") { openURL(url) }
                    .appFont(.caption)
            }
        }
    }

    private var isProblem: Bool { target.state == .failed }

    private var stateText: String {
        switch target.state {
        case .open: "チェックを待っています"
        case .verifying: "develop の Build を待っています"
        case .done: target.pullRequest == nil ? "入っていました" : "入れました"
        case .failed: "止まりました"
        case .skipped: "出していません"
        case .stopped: "PR を閉じました"
        }
    }
}

/// リポジトリとテンプレートごとに入っている版
private struct InstalledSection: View {
    let appKit: AppKitOverview

    @Environment(ClientStore.self) private var store

    var body: some View {
        CardSection {
            ForEach(store.snapshot?.repositories ?? []) { repository in
                NavigationLink(value: AppRoute.repository(repository.id)) {
                    InstalledRow(name: repository.appName, installed: repository.appKit?.installed, latest: appKit.latest?.version)
                }
            }
            ForEach(appKit.templates) { template in
                InstalledRow(name: template.repository, installed: template.installed, latest: appKit.latest?.version, isTemplate: true)
            }
        } header: {
            Text("入っている版")
        } footer: {
            Text("ずれは司令塔が 6 時間ごとに確かめます。直すには、同じ版をもう一度広げます。テンプレートの初めての入れ替えは手で行います")
        }
    }
}

private struct InstalledRow: View {
    let name: String
    let installed: AppKitInstallation?
    let latest: String?
    var isTemplate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(name, systemImage: isTemplate ? "doc.on.doc" : "folder").rowFont(.subtitle).lineLimit(1)
                Spacer()
                Text(versionText).appFont(.caption).foregroundStyle(isBehind || hasDrift ? Theme.warning : Color.secondary)
            }
            ForEach(installed?.drift ?? [], id: \.self) { problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill").appFont(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private var hasDrift: Bool { !(installed?.drift.isEmpty ?? true) }

    private var isBehind: Bool {
        guard let version = installed?.version, let latest else { return false }
        return AppKitOverview.isNewer(latest, than: version)
    }

    private var versionText: String {
        guard let installed else { return "入れ替えていません" }
        return hasDrift ? "\(installed.versionLabel)（ずれています）" : installed.versionLabel
    }
}

/// 前の版（変更点と、戻すときに広げる）
private struct PreviousReleasesSection: View {
    let appKit: AppKitOverview
    @Binding var confirming: AppKitOverview.Release?

    @Environment(ClientStore.self) private var store

    var body: some View {
        let shown = appKit.newRelease ?? appKit.latest
        CardSection {
            ForEach(appKit.releases.filter { $0.id != shown?.id }) { release in
                DisclosureGroup(release.version) {
                    if let changes = release.changes {
                        RenderedBodyView(content: RenderedBody(body: changes)).appFont(.callout)
                    }
                    let intent = HumanIntent.rolloutAppKit(version: release.version, ref: release.ref)
                    if store.supports(intent), appKit.rollout?.version != release.version {
                        Button("\(release.version) を広げる（戻す）…") { confirming = release }
                            .disabled(store.isReflecting([.appKit]))
                    }
                }
            }
        } header: {
            Text("前の版")
        }
    }
}

/// リポジトリの画面の「app-kit」。入っている版・ずれ・広げている版のこのリポジトリの PR
struct AppKitRepositorySection: View {
    let repository: TargetRepository
    let appKit: RepositoryAppKit

    @Environment(\.openURL) private var openURL
    @Environment(ClientStore.self) private var store

    var body: some View {
        CardSection {
            if let installed = appKit.installed {
                LabeledContent("版", value: installed.versionLabel)
                if let installedAt = installed.installedAt {
                    LabeledContent("入れた", value: RelativeTime.string(installedAt, now: store.currentDate()))
                }
                ForEach(installed.drift, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            } else {
                Text("まだ app-kit に入れ替えていません。「加えるときの準備」の PR で入れ替えます").foregroundStyle(.secondary)
            }
            if let version = appKit.rolloutVersion, let target = appKit.rolloutTarget, target.state != .done {
                LabeledContent("\(version) を広げる", value: rolloutText(target))
                if let url = target.pullRequestURL, let number = target.pullRequest {
                    Button("PR #\(number) を GitHub で見る") { openURL(url) }
                }
            }
            NavigationLink("app-kit の版と広げる様子", value: AppRoute.appKit)
        } header: {
            Text("app-kit")
        } footer: {
            if appKit.installed?.drift.isEmpty == false {
                Text("写すファイルを直すときは app-kit で直して版を上げます。ずれを直すには、app-kit の画面で同じ版をもう一度広げます")
            }
        }
    }

    private func rolloutText(_ target: AppKitOverview.Target) -> String {
        switch target.state {
        case .open: "PR のチェックを待っています"
        case .verifying: "develop の Build を待っています"
        case .done: "入れました"
        case .failed: target.problem.map { "止まりました（\($0)）" } ?? "止まりました"
        case .skipped: target.problem ?? "出していません"
        case .stopped: "やめました"
        }
    }
}
