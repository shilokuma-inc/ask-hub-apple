//
//  AskHub.swift
//  AskHub
//
//  Created by 村石 拓海 on 2024/05/12.
//

import SwiftUI

@main
struct AskHub: App {
    @AppStorage(DemoScenario.preferenceKey) private var scenario: DemoScenario = .standard
    @AppStorage(DataSource.preferenceKey) private var dataSource: DataSource = .stateRepository
    @AppStorage(StateConnection.repositoryPreferenceKey) private var stateRepository = StateConnection.defaultRepository
    @State private var store: ClientStore
    @State private var navigator: AppNavigator
    #if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #endif

    init() {
        let stored = UserDefaults.standard.string(forKey: DemoScenario.preferenceKey).flatMap(DemoScenario.init(rawValue:))
        // 撮影モードは、設定のデモの場面によらず標準の場面で撮る
        let scenario = ScreenshotDemo.isEnabled ? .standard : stored ?? .standard
        _store = State(initialValue: Self.makeStore(source: DataSource.current(), scenario: scenario))
        let navigator = AppNavigator()
        // App Store のスクショの撮影モードでは、撮る画面を開く（Release でも動く）
        ScreenshotDemo.openInitialScreen(ScreenshotDemo.scene, in: navigator)
        #if DEBUG
        // UI テストと撮影では、起動引数で決めた画面を開く
        if let destination = DemoLaunch.initialDestination() {
            navigator.section = destination.section
            if let route = destination.route {
                navigator.open(route, in: destination.section)
            }
        }
        #endif
        _navigator = State(initialValue: navigator)
        // 英数字は Nunito、かなと漢字はシステムの書体（Typography）
        AppFont.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .appFont(.body)
                .lineHeight(AppFont.lineHeight)
                .environment(store)
                .environment(navigator)
                .environment(appDelegate.push)
                // 設定でデータかデモの場面を変えたら、そのデータで作り直す（撮影モードは標準の場面のまま）
                .onChange(of: scenario) { reloadStore() }
                .onChange(of: dataSource) { reloadStore() }
                .onChange(of: stateRepository) { reloadStore() }
                // 状態リポジトリにつないだら、通知の許可を確かめて宛先を書く（デモのデータでは何もしない）
                .task(id: ObjectIdentifier(store)) { await appDelegate.push.activate() }
                // 通知を押したら、該当の epic・Mac の画面を開く
                .task(id: appDelegate.push.pendingTarget) {
                    guard let target = appDelegate.push.pendingTarget else {
                        return
                    }
                    navigator.open(target)
                    appDelegate.push.pendingTarget = nil
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands { AppCommands(navigator: navigator, store: store) }
        #if os(macOS)
        Settings {
            AppSettingsView()
                .appFont(.body)
                .lineHeight(AppFont.lineHeight)
                .environment(store)
                .environment(navigator)
                .environment(appDelegate.push)
                .frame(width: 520, height: 620)
        }
        #endif
    }

    private func reloadStore() {
        store = Self.makeStore(source: DataSource.current(), scenario: ScreenshotDemo.isEnabled ? .standard : scenario)
        // 撮影モードでは、起動引数で開いた撮る画面を残す
        guard !ScreenshotDemo.isEnabled else {
            return
        }
        navigator.selection = nil
        navigator.paths = [:]
    }

    /// 既定は状態リポジトリ。設定でデモのデータを選んだときと、UI テストと撮影（起動引数 `-demoScenario <場面>`
    /// `-demoReactionDelay <秒>` `-demoSendDelay <秒>` で場面と機械の反応・送るのにかかる速さを決める。
    /// `-demoReceiptDelay <秒>` `-demoRejectIntents YES` `-demoStallAfter <秒>` で司令塔の受け取りを遅らせる・断る。
    /// `-demoGitHubRemaining <回数>` で GitHub の REST の残りを決める）はデモで動く
    static func makeStore(source: DataSource, scenario: DemoScenario, defaults: UserDefaults = .standard) -> ClientStore {
        if source == .stateRepository {
            return ClientStore(service: StateConnection.makeService())
        }
        let reactionDelay = DemoScenario.seconds(forKey: DemoScenario.reactionDelayKey, in: defaults)
        // 撮影モードでは機械の反応を起こさず、撮っている間に画面が変わらないようにする
        let delay = ScreenshotDemo.isEnabled ? 3_600 : reactionDelay ?? 4
        // 判断のカードのスクショでは時計を止め、Before と After の時刻の文をそろえる
        let now: () -> Date = DemoScenario.clock(in: defaults).map { fixed in { fixed } } ?? Date.init
        let service = DemoClientService(
            scenario: scenario,
            reactionDelay: delay,
            sendDelay: .seconds(DemoScenario.seconds(forKey: DemoScenario.sendDelayKey, in: defaults) ?? 0),
            receiptDelay: DemoScenario.seconds(forKey: DemoScenario.receiptDelayKey, in: defaults),
            rejectsIntents: defaults.bool(forKey: DemoScenario.rejectsIntentsKey),
            githubRemaining: defaults.string(forKey: DemoScenario.githubRemainingKey).flatMap(Int.init),
            now: now
        )
        let stallThreshold = DemoScenario.seconds(forKey: DemoScenario.stallThresholdKey, in: defaults)
        return ClientStore(service: service, stallThreshold: stallThreshold ?? ClientStore.defaultStallThreshold, now: now)
    }
}

/// Mac のメニューとキーボードショートカット
struct AppCommands: Commands {
    let navigator: AppNavigator
    let store: ClientStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("新しい依頼…") { navigator.isShowingNewRequest = true }
                .keyboardShortcut("n")
        }
        CommandMenu("移動") {
            ForEach(Array(AppSection.allCases.enumerated()), id: \.element) { index, section in
                Button(section.title) { navigator.section = section }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
            }
            Divider()
            Button("読み直す") {
                Task { await store.refresh() }
            }
            .keyboardShortcut("r")
        }
    }
}
