import SwiftUI

extension View {
    /// 画面の行き先を付ける
    func routeDestinations() -> some View {
        navigationDestination(for: AppRoute.self) { route in
            RouteDestination(route: route)
        }
    }
}

/// 行き先ごとの画面
struct RouteDestination: View {
    let route: AppRoute

    var body: some View {
        Group {
            switch route {
            case .epic(let id):
                EpicDetailView(epicID: id)

            case .deck(let scope):
                DecisionDeckView(scope: scope)

            case .goal(let id):
                GoalReviewView(epicID: id)

            case let .humanTask(epicID, taskID):
                HumanTaskView(epicID: epicID, taskID: taskID)

            case .finalReview(let id):
                FinalReviewView(epicID: id)

            case .mac(let id):
                MacDetailView(macID: id)

            case .cleanup(let id):
                CleanupView(macID: id)

            case .repository(let id):
                RepositoryDetailView(repositoryID: id)

            case let .release(repositoryID, version):
                ReleaseDetailView(repositoryID: repositoryID, version: version)

            case .finishedEpics:
                FinishedEpicListView()
            }
        }
        .sendStatusBar()
    }
}

/// タブ（サイドバーの項目）ごとの一覧
struct SectionRootView: View {
    let section: AppSection
    let selection: Binding<AppRoute?>?

    var body: some View {
        Group {
            switch section {
            case .inbox:
                InboxView(selection: selection)

            case .progress:
                EpicListView(selection: selection)

            case .macs:
                MacListView(selection: selection)

            case .repositories:
                RepositoryListView(selection: selection)
            }
        }
        .sendStatusBar()
    }
}
