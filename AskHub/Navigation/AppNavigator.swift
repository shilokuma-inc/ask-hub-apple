import Observation
import SwiftUI

/// 画面の移動の状態。iPhone はタブごとの積み重ね、Mac・iPad は一覧の選択と詳細の積み重ねで持つ
@Observable
final class AppNavigator {
    var section: AppSection = .inbox
    /// iPhone: タブごとに開いている画面
    var paths: [AppSection: [AppRoute]] = [:]
    /// Mac・iPad: 一覧で選んでいる項目
    var selection: AppRoute?
    /// Mac・iPad: 詳細の中で開いた画面
    var detailPath: [AppRoute] = []
    var isShowingNewRequest = false
    var isShowingSettings = false

    func path(for section: AppSection) -> Binding<[AppRoute]> {
        Binding { self.paths[section] ?? [] } set: { self.paths[section] = $0 }
    }

    /// 通知やほかの画面から、決まった画面を開く
    func open(_ route: AppRoute, in section: AppSection = .inbox) {
        self.section = section
        paths[section] = [route]
        selection = route
        detailPath = []
    }
}

/// 一覧。Mac・iPad では選択を詳細の列に渡し、iPhone では押すと積み重ねる
struct RouteList<Content: View>: View {
    let selection: Binding<AppRoute?>?
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if let selection {
                List(selection: selection, content: content)
            } else {
                List(content: content)
            }
        }
        .compactList()
    }
}

extension View {
    /// 判断に集中する画面では、iPhone のタブバーを隠して場所を空ける
    func hidesTabBar() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    func sendStatusBar() -> some View {
        modifier(SendStatusBarModifier())
    }
}

extension EnvironmentValues {
    /// 画面ごとに取り消しの帯を出すか。Mac・iPad の 3 列では全体の下に 1 つだけ出すので、列の中では出さない
    @Entry var showsSendStatusBar = true
}

private struct SendStatusBarModifier: ViewModifier {
    @Environment(\.showsSendStatusBar) private var showsSendStatusBar

    func body(content: Content) -> some View {
        if showsSendStatusBar {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                SendStatusBar()
                    .padding(.bottom, 8)
            }
        } else {
            content
        }
    }
}

/// どの一覧にも置く ＋（依頼）と設定のボタン
struct SectionToolbar: ToolbarContent {
    @Environment(AppNavigator.self) private var navigator

    var body: some ToolbarContent {
        #if os(iOS)
        ToolbarItem(placement: .topBarLeading) {
            Button("設定", systemImage: "gearshape") { navigator.isShowingSettings = true }
        }
        #endif
        ToolbarItem(placement: .primaryAction) {
            Button("新しい依頼", systemImage: "plus") { navigator.isShowingNewRequest = true }
        }
    }
}
