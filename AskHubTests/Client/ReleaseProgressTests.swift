@testable import AskHub
import Foundation
import Testing

/// 「進行中」のリリース: 終わっていない審査と、後作業の残っている配信した版を並べ、終わったものと外したリポジトリのものは出さない
@MainActor
struct ReleaseProgressTests {
    @Test
    func listsOngoingSubmissionsAndUnfinishedReleases() {
        let snapshot = DemoScenario.standard.snapshot(now: Date())
        let items = ReleaseProgress.items(in: snapshot)
        let ongoing = snapshot.submissions.filter { !$0.isEnded && !snapshot.isRemoved($0.repositoryID) }
        let unfinished = snapshot.releases.filter { !$0.isFinished && !snapshot.isRemoved($0.repositoryID) }
        #expect(!items.isEmpty)
        #expect(items.count == ongoing.count + unfinished.count)
        // 審査を先に、後作業を後に並べる
        let kinds = items.map { if case .submission = $0 { 0 } else { 1 } }
        #expect(kinds == kinds.sorted())
        #expect(items.allSatisfy { item in
            switch item {
            case .submission(let submission): !submission.isEnded
            case .release(let release): !release.isFinished
            }
        })
    }

    @Test
    func routesToTheReleaseScreens() {
        let snapshot = DemoScenario.standard.snapshot(now: Date())
        for item in ReleaseProgress.items(in: snapshot) {
            switch item {
            case .submission(let submission):
                #expect(item.route == .submission(repositoryID: submission.repositoryID, version: submission.version))
            case .release(let release):
                #expect(item.route == .release(repositoryID: release.repositoryID, version: release.version))
            }
        }
    }
}
