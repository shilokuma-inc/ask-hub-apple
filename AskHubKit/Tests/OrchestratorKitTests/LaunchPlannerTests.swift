import Foundation
@testable import OrchestratorKit
import Testing

struct LaunchPlannerTests {
    private let app = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
    private let other = RepositoryConfig(owner: "shilokuma-inc", name: "beat-tap-ios", checkoutPath: "/src/beat-tap-ios")

    private func config() throws -> OrchestratorConfig {
        OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [app, other],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["/usr/local/bin/start-loop"])
        )
    }

    @Test func launchesTrustedDiscussionOfAssignedIdleRepository() throws {
        let discussion = ReadyDiscussion.fixture(repository: "Shilokuma-Inc/Ask-Hub-Apple", number: 3)
        let decisions = LaunchPlanner.decide([discussion], config: try config(), statuses: [:])
        #expect(decisions == [.launch(discussion, app)])
    }

    @Test func skipsDiscussionOfOtherPC() throws {
        let discussion = ReadyDiscussion.fixture(repository: "shilokuma-inc/notti-ios")
        let decisions = LaunchPlanner.decide([discussion], config: try config(), statuses: [:])
        #expect(decisions == [.skip(discussion, .notAssigned)])
    }

    @Test func skipsUntrustedOrDeletedAuthor() throws {
        let untrusted = ReadyDiscussion.fixture(number: 1, author: "someone")
        let deleted = ReadyDiscussion.fixture(number: 2, author: nil)
        let decisions = LaunchPlanner.decide([untrusted, deleted], config: try config(), statuses: [:])
        #expect(decisions == [.skip(untrusted, .untrustedAuthor), .skip(deleted, .untrustedAuthor)])
    }

    @Test func skipsManualLoopDiscussion() throws {
        let manual = ReadyDiscussion.fixture(number: 1, isManualLoop: true)
        let next = ReadyDiscussion.fixture(number: 2)
        let decisions = LaunchPlanner.decide([manual, next], config: try config(), statuses: [:])
        #expect(decisions == [.skip(manual, .manualLoop), .launch(next, app)])
        // 信用外の author なら、manual-loop より先に信用外として扱う
        let untrusted = ReadyDiscussion.fixture(number: 3, author: "someone", isManualLoop: true)
        #expect(LaunchPlanner.decide([untrusted], config: try config(), statuses: [:]) == [.skip(untrusted, .untrustedAuthor)])
    }

    @Test func waitsForManualLoopOfTrustedAuthorInSameRepositoryOnly() throws {
        let discussion = ReadyDiscussion.fixture(repository: "shilokuma-inc/ask-hub-apple", number: 5)
        let otherRepository = ReadyDiscussion.fixture(repository: "shilokuma-inc/beat-tap-ios", number: 6)
        let decisions = LaunchPlanner.decide(
            [discussion, otherRepository],
            config: try config(),
            statuses: [:],
            manualLoops: [
                ManualLoopDiscussion(repository: "Shilokuma-Inc/Ask-Hub-Apple", number: 4, author: "mrs1669"),
                ManualLoopDiscussion(repository: "shilokuma-inc/ask-hub-apple", number: 2, author: "mrs1669"),
                // 信用外の author の manual-loop は無視する
                ManualLoopDiscussion(repository: "shilokuma-inc/beat-tap-ios", number: 3, author: "someone")
            ]
        )
        #expect(decisions == [.skip(discussion, .manualLoopInProgress(number: 2)), .launch(otherRepository, other)])
    }

    @Test func skipsWhileLoopIsRunningOrStateRemains() throws {
        let running = ReadyDiscussion.fixture(repository: "shilokuma-inc/ask-hub-apple")
        let remaining = ReadyDiscussion.fixture(repository: "shilokuma-inc/beat-tap-ios")
        let decisions = LaunchPlanner.decide(
            [running, remaining],
            config: try config(),
            statuses: [
                "shilokuma-inc/ask-hub-apple": LoopStatus(stateFileExists: true, processAlive: true),
                "shilokuma-inc/beat-tap-ios": LoopStatus(stateFileExists: true, processAlive: false)
            ]
        )
        #expect(decisions == [.skip(running, .loopRunning), .skip(remaining, .loopStateRemains)])
    }

    @Test func skipsDiscussionAlreadyLaunched() throws {
        let launched = ReadyDiscussion.fixture(number: 3)
        let next = ReadyDiscussion.fixture(number: 5)
        let decisions = LaunchPlanner.decide([launched, next], config: try config(), statuses: [:], excluding: ["D_3"])
        #expect(decisions == [.skip(launched, .alreadyLaunched), .launch(next, app)])
    }

    @Test func waitsForEpicInProgressInSameRepositoryOnly() throws {
        let discussion = ReadyDiscussion.fixture()
        let decisions = LaunchPlanner.decide(
            [discussion],
            config: try config(),
            statuses: [:],
            epicsInProgress: ["shilokuma-inc/ask-hub-apple"]
        )
        #expect(decisions == [.skip(discussion, .epicInProgress)])

        let other = LaunchPlanner.decide([discussion], config: try config(), statuses: [:], epicsInProgress: ["shilokuma-inc/notti-ios"])
        #expect(other == [.launch(discussion, try config().repositories[0])])
    }

    @Test func skipsWhenStateFileCannotBeChecked() throws {
        let discussion = ReadyDiscussion.fixture()
        let decisions = LaunchPlanner.decide(
            [discussion],
            config: try config(),
            statuses: ["shilokuma-inc/ask-hub-apple": LoopStatus(stateFileExists: nil, processAlive: false)]
        )
        #expect(decisions == [.skip(discussion, .loopStatusUnknown)])
    }

    @Test func launchesProcessAliveWithoutStateFileAsRunning() throws {
        // state ファイルを作る前の起動直後も、起動したプロセスが生きていれば二重に起動しない
        let discussion = ReadyDiscussion.fixture()
        let decisions = LaunchPlanner.decide(
            [discussion],
            config: try config(),
            statuses: ["shilokuma-inc/ask-hub-apple": LoopStatus(stateFileExists: false, processAlive: true)]
        )
        #expect(decisions == [.skip(discussion, .loopRunning)])
    }

    @Test func launchesOnlyOldestDiscussionPerRepository() throws {
        let newer = ReadyDiscussion.fixture(number: 9)
        let older = ReadyDiscussion.fixture(number: 4)
        let otherRepository = ReadyDiscussion.fixture(repository: "shilokuma-inc/beat-tap-ios", number: 7)
        let decisions = LaunchPlanner.decide([newer, otherRepository, older], config: try config(), statuses: [:])
        #expect(decisions == [
            .launch(older, app),
            .launch(otherRepository, other),
            .skip(newer, .waitingForAnotherDiscussion(number: 4))
        ])
    }
}

extension ReadyDiscussion {
    static func fixture(
        repository: String = "shilokuma-inc/ask-hub-apple",
        number: Int = 1,
        author: String? = "mrs1669",
        isManualLoop: Bool = false
    ) -> Self {
        Self(
            nodeID: "D_\(number)",
            repository: repository,
            number: number,
            title: "Discussion \(number)",
            url: URL(string: "https://github.com/\(repository)/discussions/\(number)")!,
            author: author,
            readyLabelID: "LA_ready",
            isManualLoop: isManualLoop
        )
    }
}
