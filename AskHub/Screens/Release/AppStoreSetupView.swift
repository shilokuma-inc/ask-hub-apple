import SwiftUI

/// 新しいアプリを App Store に載せる準備のチェックリスト。司令塔が App Store Connect で確かめた項目の様子を並べ、
/// アプリを作る手順・決まった値を書く・Web でした作業を「終わった」にする・App Store に出さないを押せる
struct AppStoreSetupView: View {
    let repositoryID: TargetRepository.ID

    @Environment(ClientStore.self) private var store
    @State private var isWriting = Self.initialWriting
    @State private var isRegistering = false

    /// 撮影では、起動引数で決まった値を書くシートを開いておく
    private static var initialWriting: Bool {
        #if DEBUG
        DemoLaunch.initialSheet() == .appStoreSettings
        #else
        false
        #endif
    }

    var body: some View {
        if let setup = store.snapshot?.appStoreSetup(of: repositoryID) {
            content(setup)
        } else {
            ContentUnavailableView("App Store の準備はありません", systemImage: "checklist")
        }
    }

    private func content(_ setup: AppStoreSetup) -> some View {
        let target = IntentTarget.appStore(setup.repositoryID)
        let firstRelease = store.snapshot?.isFirstRelease(of: setup.repositoryID) ?? false
        return List {
            CardSection {
                AppHeaderView(repository: store.repository(setup.repositoryID), iconSize: 40) {
                    Text(summary(setup, firstRelease: firstRelease)).appFont(.footnote).foregroundStyle(.secondary)
                }
                // 操作を送った後に、司令塔がしばらく受け取っていない・断ったときの理由
                ReflectionStatusView(target)
                if let problem = setup.problem {
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                }
                ForEach(setup.failures, id: \.self) { failure in
                    Label("\(failure.item.title): \(failure.message)", systemImage: "xmark.octagon.fill").foregroundStyle(Theme.danger)
                }
            }
            if setup.isActive {
                appSection(setup)
                if setup.app != nil {
                    settingsSection(setup)
                    webSection(setup)
                    if setup.items.contains(where: \.kind.isVersionItem) {
                        versionSection(setup)
                    }
                }
            }
            exclusionSection(setup)
        }
        .pastelBackground()
        .compactList()
        .navigationTitle("App Store の準備")
        .disabled(store.isReflecting([target]))
        .sheet(isPresented: $isWriting) {
            AppStoreSettingsSheet(setup: setup) { isWriting = false }
        }
        .confirmationDialog("Bundle ID を登録しますか？", isPresented: $isRegistering, titleVisibility: .visible) {
            if let identifier = setup.mainBundleID {
                ForEach(AppStoreSetup.BundlePlatform.allCases, id: \.self) { platform in
                    Button("\(platform.label)で登録する") {
                        send(.registerBundleId(repositoryID: setup.repositoryID, identifier: identifier, platform: platform))
                    }
                }
            }
        } message: {
            let identifier = setup.mainBundleID ?? ""
            Text("司令塔が App Store Connect の Certificates, Identifiers & Profiles に \(identifier) を登録します。"
                + "鍵の役割で断られたら、develop への push の Upload が登録します")
        }
    }

    private func summary(_ setup: AppStoreSetup, firstRelease: Bool) -> String {
        if setup.isExcluded { return "App Store に出さないリポジトリです" }
        if setup.releasedAt != nil { return "初めての版を配信しました" }
        let remaining = setup.pendingItems(firstRelease: true).count
        if setup.app == nil { return "アプリがまだ無い · 残り \(remaining)" }
        return remaining == 0 ? "準備は終わっています" : (firstRelease ? "初めての版を審査に出すまでに、残り \(remaining)" : "残り \(remaining)")
    }

    // MARK: - アプリを作る

    @ViewBuilder private func appSection(_ setup: AppStoreSetup) -> some View {
        CardSection {
            ForEach(setup.items.filter(\.kind.isNeededForApp)) { item in
                ChecklistRow(item: item)
            }
            if setup.item(.bundleId)?.isDone == false, let identifier = setup.mainBundleID,
               store.supports(.registerBundleId(repositoryID: setup.repositoryID, identifier: identifier, platform: .iOS)) {
                Button("Bundle ID を登録する…", systemImage: "plus.circle") { isRegistering = true }
                    .accessibilityIdentifier("app-store-register-bundle-id")
            }
            if setup.app == nil {
                AppRecordValues(setup: setup, appName: store.repository(setup.repositoryID)?.appName)
                if let url = URL(string: "https://appstoreconnect.apple.com/apps") {
                    Link(destination: url) { Label("App Store Connect を開く", systemImage: "safari") }
                }
            }
            confirmButton(setup, .bundleId)
        } header: {
            Text("アプリを作る")
        } footer: {
            Text(setup.app == nil
                ? "アプリの作成は App Store Connect の Web でしかできません。作ると 30 分以内に AskHub が見つけて、次の項目に進みます"
                : "App Store Connect にアプリがあります。TestFlight に上げられます")
        }
    }

    // MARK: - AskHub から書ける

    @ViewBuilder private func settingsSection(_ setup: AppStoreSetup) -> some View {
        let kinds = AppStoreSetup.ItemKind.settingKinds
        CardSection {
            ForEach(setup.items.filter { kinds.contains($0.kind) && !$0.kind.isVersionItem }) { item in
                ChecklistRow(item: item)
            }
            writeButton(setup, versionItems: false)
        } header: {
            Text("AskHub から書けるもの")
        } footer: {
            Text("あなたが値を確かめて押したときだけ、司令塔が App Store Connect に書きます。App Store Connect で決めた値は上書きしません")
        }
    }

    // MARK: - App Store Connect の Web で

    @ViewBuilder private func webSection(_ setup: AppStoreSetup) -> some View {
        let kinds: [AppStoreSetup.ItemKind] = [.ageRating, .appPrivacy, .digitalServicesAct]
        CardSection {
            ForEach(setup.items.filter { kinds.contains($0.kind) }) { item in
                VStack(alignment: .leading, spacing: 6) {
                    ChecklistRow(item: item)
                    if !item.isDone, let guide = item.kind.guide {
                        Text(guide).appFont(.footnote).foregroundStyle(.secondary)
                    }
                }
                confirmButton(setup, item.kind)
            }
            if let url = setup.app?.url {
                Link(destination: url) { Label("App Store Connect でこのアプリを開く", systemImage: "safari") }
            }
        } header: {
            Text("App Store Connect の Web で")
        } footer: {
            Text("API が無い・AskHub から書かない項目です。年齢制限は答えると AskHub が見つけます。App のプライバシーと DSA は、終わったら「終わった」を押してください")
        }
    }

    // MARK: - 初めての版

    @ViewBuilder private func versionSection(_ setup: AppStoreSetup) -> some View {
        let version = store.snapshot?.submissions(of: setup.repositoryID).first { !$0.isEnded }?.version
        CardSection {
            ForEach(setup.items.filter(\.kind.isVersionItem)) { item in
                VStack(alignment: .leading, spacing: 6) {
                    ChecklistRow(item: item)
                    if !item.isDone, let guide = item.kind.guide {
                        Text(guide).appFont(.footnote).foregroundStyle(.secondary)
                    }
                }
                confirmButton(setup, item.kind)
            }
            if let source = setup.settingsRequest?.reviewContactFrom {
                Label("App Review の連絡先を「\(source)」の版から写しました", systemImage: "person.crop.rectangle.stack")
                    .appFont(.footnote)
                    .foregroundStyle(.secondary)
            }
            writeButton(setup, versionItems: true)
        } header: {
            Text(version.map { "初めての版（\($0)）" } ?? "初めての版")
        } footer: {
            Text("リリースを始めて App Store Connect に版ができると出ます。あなたが値を確かめて押したら、司令塔が書きます"
                + "（App Review の連絡先は、同じ鍵のほかのアプリの版から写します。連絡先は AskHub に置きません）")
        }
    }

    /// 値を書くシートを開く（そのまとまりに、まだ決めていない書ける項目があるときだけ）。書いている間は様子を出す
    @ViewBuilder private func writeButton(_ setup: AppStoreSetup, versionItems: Bool) -> some View {
        if setup.writableItems.contains(where: { $0.kind.isVersionItem == versionItems }) {
            if setup.isWriting {
                Label("司令塔が App Store Connect に書いています", systemImage: "clock").foregroundStyle(.secondary)
            } else {
                Button("値を確かめて App Store Connect に書く…", systemImage: "square.and.pencil") { isWriting = true }
                    .accessibilityIdentifier(versionItems ? "app-store-write-version" : "app-store-write-settings")
            }
        }
    }

    /// 「終わった」（API で確かめられない項目と、確かめが合わない・書けなかったときに Web でした作業）
    @ViewBuilder private func confirmButton(_ setup: AppStoreSetup, _ kind: AppStoreSetup.ItemKind) -> some View {
        if let item = setup.item(kind), !item.isDone, item.state != .done,
           kind.needsConfirmation || item.state == .unknown || setup.failures.contains(where: { $0.item == kind }),
           store.supports(.confirmAppStoreItem(repositoryID: setup.repositoryID, item: kind)) {
            Button("\(kind.title)は終わった", systemImage: "checkmark.circle") {
                send(.confirmAppStoreItem(repositoryID: setup.repositoryID, item: kind))
            }
            .accessibilityIdentifier("app-store-confirm-\(kind.rawValue)")
        }
    }

    // MARK: - 出さない

    @ViewBuilder private func exclusionSection(_ setup: AppStoreSetup) -> some View {
        if setup.releasedAt == nil {
            let excluded = !setup.isExcluded
            if store.supports(.excludeFromAppStore(repositoryID: setup.repositoryID, excluded: excluded)) {
                CardSection {
                    Button(excluded ? "App Store に出さない" : "App Store に出すに戻す", systemImage: excluded ? "nosign" : "arrow.uturn.backward") {
                        send(.excludeFromAppStore(repositoryID: setup.repositoryID, excluded: excluded))
                    }
                    .accessibilityIdentifier("app-store-exclude")
                } footer: {
                    Text(excluded ? "試しのリポジトリなど、App Store に出さないアプリは、確かめも「あなたの番」への表示もやめます" : "戻すと、30 分以内にもう一度確かめます")
                }
            }
        }
    }

    private func send(_ intent: HumanIntent) {
        Task { await store.send(intent) }
    }
}

/// チェックリストの 1 行（済み・まだ・確かめられない）
private struct ChecklistRow: View {
    let item: AppStoreSetup.Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.kind.title).appFont(.headline, weight: .semibold)
                Text(detail).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(stateLabel)
    }

    private var detail: String {
        if item.confirmed { return "終わった（あなたが押しました）" }
        return item.note ?? (item.state == .done ? "済み" : "まだ")
    }

    private var symbol: String {
        if item.isDone { return "checkmark.circle.fill" }
        return item.state == .unknown ? "questionmark.circle" : "circle"
    }

    private var tint: Color {
        if item.isDone { return Theme.Tone.mint }
        return item.state == .unknown ? Theme.Tone.butter : Theme.Tone.lavender
    }

    private var stateLabel: String {
        if item.isDone { return "済み" }
        return item.state == .unknown ? "確かめられない" : "まだ"
    }
}

/// App Store Connect でアプリを作るときに入れる値（コピーできる）
private struct AppRecordValues: View {
    let setup: AppStoreSetup
    let appName: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("新規 App に入れる値").appFont(.footnote, weight: .semibold).foregroundStyle(.secondary)
            if let appName { value("名前", appName) }
            value("プライマリ言語", "日本語")
            if let identifier = setup.mainBundleID {
                value("バンドル ID", identifier)
                value("SKU", identifier)
            }
            value("ユーザアクセス", "フルアクセス")
        }
    }

    private func value(_ label: String, _ text: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).appFont(.caption).foregroundStyle(.secondary)
                Text(text).font(.callout.monospaced()).textSelection(.enabled)
            }
            Spacer()
            CopyButton(value: text)
        }
    }
}
