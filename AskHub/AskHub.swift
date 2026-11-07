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
                // 設定でデータかデモの場面を変えたら、そのデータで作り直す（撮影モードは標準の場面のまま）
                .onChange(of: scenario) { reloadStore() }
                .onChange(of: dataSource) { reloadStore() }
                .onChange(of: stateRepository) { reloadStore() }
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
    /// `-demoReactionDelay <秒>` `-demoSendDelay <秒>` で場面と機械の反応・送るのにかかる速さを決める）はデモで動く
    static func makeStore(source: DataSource, scenario: DemoScenario) -> ClientStore {
        if source == .stateRepository {
            return ClientStore(service: StateConnection.makeService())
        }
        // 撮影モードでは機械の反応を起こさず、撮っている間に画面が変わらないようにする
        let delay = ScreenshotDemo.isEnabled ? 3_600 : UserDefaults.standard.object(forKey: DemoScenario.reactionDelayKey) as? Double ?? 4
        let sendDelay = UserDefaults.standard.double(forKey: DemoScenario.sendDelayKey)
        return ClientStore(service: DemoClientService(scenario: scenario, reactionDelay: delay, sendDelay: .seconds(sendDelay)))
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
