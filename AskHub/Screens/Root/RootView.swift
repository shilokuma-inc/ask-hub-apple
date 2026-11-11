import SwiftUI

/// 画面の一番外側。iPhone はタブ、Mac と iPad は 3 列（サイドバー・一覧・詳細）にする
struct RootView: View {
    @Environment(ClientStore.self) private var store
    @Environment(AppNavigator.self) private var navigator
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif

    var body: some View {
        @Bindable var navigator = navigator
        layout
            // テキストサイズが変わったら、UIKit が描くバーの見出しも新しい大きさで作り直す（Typography）
            .id(dynamicTypeSize)
            .onChange(of: dynamicTypeSize) { AppFont.applyToSystemBars() }
            // 主な色はラベンダー（パステルの見た目。Theme）
            .tint(Theme.accent)
            // 開いている間（バックグラウンド以外）は決まった間隔で取り直す。デモの場面を変えて store を作り直したら、新しい store で回し直す
            .task(id: AutoRefreshKey(isActive: scenePhase != .background, store: ObjectIdentifier(store))) {
                guard scenePhase != .background else {
                    return
                }
                await store.runAutoRefresh()
            }
            .sheet(isPresented: $navigator.isShowingNewRequest) {
                NewRequestSheet()
            }
            #if os(iOS)
            .sheet(isPresented: $navigator.isShowingSettings) {
                AppSettingsView()
            }
            #endif
    }

    /// 取り直しを回し直すきっかけ（バックグラウンドから戻った・store が替わった）
    private struct AutoRefreshKey: Hashable {
        let isActive: Bool
        let store: ObjectIdentifier
    }

    @ViewBuilder private var layout: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            TabRootView()
        } else {
            SplitRootView()
        }
        #else
        SplitRootView()
            // 窓を小さくすると詳細の列が潰れるので、3 列（サイドバー・一覧・詳細の最小の幅）が収まる大きさより小さくしない
            .frame(minWidth: SplitRootView.minimumWindowSize.width, minHeight: SplitRootView.minimumWindowSize.height)
            // macOS 27 では、ツールバーの下が不透明の帯になり、詳細の列だけ白く抜ける。26 と同じく、列のパステルを透かす
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        #endif
    }
}

#if os(iOS)
/// iPhone のタブ
struct TabRootView: View {
    @Environment(ClientStore.self) private var store
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        TabView(selection: $navigator.section) {
            ForEach(AppSection.allCases) { section in
                Tab(section.title, systemImage: section.systemImage, value: section) {
                    NavigationStack(path: navigator.path(for: section)) {
                        SectionRootView(section: section, selection: nil)
                            .routeDestinations()
                    }
                }
                .badge(section == .inbox ? store.blockingCount : 0)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }
}
#endif

/// Mac と iPad の 3 列
struct SplitRootView: View {
    /// Mac の窓の最小の大きさ。サイドバー（180）・一覧（300）・詳細（440）の最小の幅が並ぶ
    static let minimumWindowSize = CGSize(width: 960, height: 600)

    @Environment(ClientStore.self) private var store
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        @Bindable var navigator = navigator
        NavigationSplitView {
            SidebarView()
        } content: {
            SectionRootView(section: navigator.section, selection: $navigator.selection)
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 480)
        } detail: {
            NavigationStack(path: $navigator.detailPath) {
                if let route = navigator.selection {
                    RouteDestination(route: route)
                } else {
                    // ほかの列と同じパステルの背景にする（無いと詳細の列だけ白い）
                    ContentUnavailableView("項目を選んでください", systemImage: navigator.section.systemImage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .pastelBackground()
                }
            }
            .routeDestinations()
            // 段階の名前や判断の札が折り返さずに収まる幅（まとめて判断するの札は 440pt まで広がる）
            .navigationSplitViewColumnWidth(min: 440, ideal: 560)
        }
        .environment(\.showsSendStatusBar, false)
        .overlay(alignment: .bottom) {
            SendStatusBar()
                .padding(.bottom, 16)
        }
        .onChange(of: navigator.selection) {
            navigator.detailPath = []
        }
    }
}

/// Mac・iPad のサイドバー
struct SidebarView: View {
    @Environment(ClientStore.self) private var store
    @Environment(AppNavigator.self) private var navigator

    var body: some View {
        let selection = Binding<AppSection?> { navigator.section } set: { navigator.section = $0 ?? .inbox }
        List(selection: selection) {
            ForEach(AppSection.allCases) { section in
                Label(section.title, systemImage: section.systemImage)
                    .badge(badge(for: section))
                    .tag(section)
            }
        }
        .pastelBackground()
        .navigationTitle("AskHub")
        .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        .safeAreaInset(edge: .bottom) {
            ConnectionStatusView()
                .padding(12)
        }
    }

    private func badge(for section: AppSection) -> Int {
        switch section {
        case .inbox:
            store.blockingCount

        case .macs:
            store.snapshot?.macs.filter { !$0.isOnline }.count ?? 0

        case .progress, .repositories:
            0
        }
    }
}
