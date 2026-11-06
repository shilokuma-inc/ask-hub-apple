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
                    ContentUnavailableView("項目を選んでください", systemImage: navigator.section.systemImage)
                }
            }
            .routeDestinations()
        }
        .environment(\.showsSendStatusBar, false)
        .overlay(alignment: .bottom) {
            SendStatusBar()
                .padding(.bottom, 16)
        }
        .onChange(of: navigator.section) {
            navigator.selection = nil
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
