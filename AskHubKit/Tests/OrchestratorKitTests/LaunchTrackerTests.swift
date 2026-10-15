@testable import OrchestratorKit
import Testing

struct LaunchTrackerTests {
    private let discussion = ReadyDiscussion.fixture(number: 12)
    private let key = "shilokuma-inc/ask-hub-apple"

    private func statuses(_ status: LoopStatus) -> [String: LoopStatus] {
        [key: status]
    }

    @Test func waitsWhileProcessIsAliveOrStateFileIsUnknown() {
        var tracker = LaunchTracker()
        tracker.recordLaunch(of: discussion, repositoryKey: key)

        let alive = statuses(LoopStatus(stateFileExists: false, processAlive: true))
        let unknown = statuses(LoopStatus(stateFileExists: nil, processAlive: false))
        #expect(tracker.update(discussions: [discussion], statuses: alive).isEmpty)
        #expect(tracker.update(discussions: [discussion], statuses: unknown).isEmpty)
        #expect(tracker.blockedDiscussionIDs == ["D_12"])
    }

    @Test func tellsStartingStartedAndGivenUpDiscussionsOfRepository() {
        var tracker = LaunchTracker()
        let older = ReadyDiscussion.fixture(number: 10)
        // #10 は 3 回起動しても始まらなかった（諦めた）
        for _ in 0..<LaunchTracker.maxAttempts {
            tracker.recordLaunchFailure(of: older, repositoryKey: key)
        }
        #expect(tracker.givenUpDiscussions(repositoryKey: key) == [10])
        #expect(tracker.startingDiscussions(repositoryKey: key).isEmpty)

        // 続けて #12 を起動した。開始を待っているのは #12 で、#10 は諦めたまま
        tracker.recordLaunch(of: discussion, repositoryKey: key)
        #expect(tracker.startingDiscussions(repositoryKey: key) == [12])
        #expect(tracker.startedDiscussions(repositoryKey: key).isEmpty)
        #expect(tracker.givenUpDiscussions(repositoryKey: key) == [10])
        #expect(tracker.startingDiscussions(repositoryKey: "other/repo").isEmpty)

        // ループの開始を確かめた・ラベルを外した後は、検索結果から消えるまで開始を確かめた Discussion
        let prepared = statuses(LoopStatus(stateFileExists: true, processAlive: true))
        let actions = tracker.update(discussions: [older, discussion], statuses: prepared, preparedDiscussions: [key: 12])
        #expect(actions == [.removeLabel(discussion)])
        #expect(tracker.startingDiscussions(repositoryKey: key).isEmpty)
        #expect(tracker.startedDiscussions(repositoryKey: key) == [12])
        tracker.recordLabelRemoved(from: discussion)
        #expect(tracker.startedDiscussions(repositoryKey: key) == [12])
        // 開始を確かめられないまま終わった（次の起動を待っている）Discussion は、どれにも入れない
        tracker.forgiveFailures(repositoryKey: key)
        #expect(tracker.givenUpDiscussions(repositoryKey: key).isEmpty)
        #expect(tracker.startingDiscussions(repositoryKey: key).isEmpty)
        #expect(tracker.startedDiscussions(repositoryKey: key) == [12])
        _ = tracker.update(discussions: [older], statuses: prepared)
        #expect(tracker.startedDiscussions(repositoryKey: key).isEmpty)
    }

    @Test func adoptsLoopStartedBeforeRestartOnlyWhenUntracked() {
        var tracker = LaunchTracker()
        tracker.adoptStarted(discussion, repositoryKey: key)
        #expect(tracker.update(discussions: [discussion], statuses: statuses(.idle)) == [.removeLabel(discussion)])

        // 追跡中の Discussion は上書きしない
        var launching = LaunchTracker()
        launching.recordLaunch(of: discussion, repositoryKey: key)
        launching.adoptStarted(discussion, repositoryKey: key)
        #expect(launching.entries[discussion.nodeID]?.phase == .starting)
    }

    @Test func doesNotTakeStateFileOfAnotherLoopAsStart() {
        var tracker = LaunchTracker()
        tracker.recordLaunch(of: discussion, repositoryKey: key)

        // 制御用 worktree が別の Discussion（前の epic）から準備されたものなら、この Discussion のループではない
        let otherLoop = statuses(LoopStatus(stateFileExists: true, processAlive: true))
        #expect(tracker.update(discussions: [discussion], statuses: otherLoop, preparedDiscussions: [key: 3]).isEmpty)
        // 起動したプロセスが終われば、state ファイルが残っていても起動の失敗とみなす
        let ended = statuses(LoopStatus(stateFileExists: true, processAlive: false))
        let actions = tracker.update(discussions: [discussion], statuses: ended, preparedDiscussions: [key: 3])
        #expect(actions == [.retry(discussion, attempts: 1)])
        #expect(tracker.blockedDiscussionIDs.isEmpty)
    }

    @Test func removesLabelOnceStateFileAppearsAndKeepsRetryingRemoval() {
        var tracker = LaunchTracker()
        tracker.recordLaunch(of: discussion, repositoryKey: key)

        let started = statuses(LoopStatus(stateFileExists: true, processAlive: false))
        let actions = tracker.update(discussions: [discussion], statuses: started, preparedDiscussions: [key: 12])
        #expect(actions == [.removeLabel(discussion)])
        // 外せていなければ、ループが終わっても外し直す
        #expect(tracker.update(discussions: [discussion], statuses: statuses(.idle)) == [.removeLabel(discussion)])

        tracker.recordLabelRemoved(from: discussion)
        #expect(tracker.update(discussions: [discussion], statuses: statuses(.idle)).isEmpty)
        #expect(tracker.blockedDiscussionIDs == ["D_12"])

        // 検索に出なくなったら追跡をやめる
        #expect(tracker.update(discussions: [], statuses: statuses(.idle)).isEmpty)
        #expect(tracker.entries.isEmpty)
    }

    @Test func retriesUntilMaxAttemptsThenGivesUp() {
        var tracker = LaunchTracker()
        for attempt in 1..<LaunchTracker.maxAttempts {
            tracker.recordLaunch(of: discussion, repositoryKey: key)
            #expect(tracker.update(discussions: [discussion], statuses: statuses(.idle)) == [.retry(discussion, attempts: attempt)])
            #expect(tracker.blockedDiscussionIDs.isEmpty)
        }
        tracker.recordLaunch(of: discussion, repositoryKey: key)
        let actions = tracker.update(discussions: [discussion], statuses: statuses(.idle))
        #expect(actions == [.giveUp(discussion, attempts: LaunchTracker.maxAttempts)])
        #expect(tracker.blockedDiscussionIDs == ["D_12"])
        #expect(tracker.update(discussions: [discussion], statuses: statuses(.idle)).isEmpty)
    }

    @Test func launchFailuresCountTowardsMaxAttempts() {
        var tracker = LaunchTracker()
        #expect(tracker.recordLaunchFailure(of: discussion, repositoryKey: key).phase == .failed)
        #expect(tracker.recordLaunchFailure(of: discussion, repositoryKey: key).phase == .failed)
        #expect(tracker.recordLaunchFailure(of: discussion, repositoryKey: key).phase == .gaveUp)
        #expect(tracker.blockedDiscussionIDs == ["D_12"])
    }
}
