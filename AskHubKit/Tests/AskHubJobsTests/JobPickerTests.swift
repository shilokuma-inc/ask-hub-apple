@testable import AskHubJobs
import AskHubProtocol
import Foundation
import Testing

struct JobPickerTests {
    private typealias Sample = Fixtures
    private let roomy = MacFile.Capacity(claude: 5, build: 5)

    @Test func picksOnlyMyReadyJobs() {
        let jobs = [
            Sample.job(1),
            Sample.job(2, mac: Sample.macMini),
            Sample.job(3, state: .queued),
            Sample.job(4, nextRunAt: Sample.stamp(10)),
            Sample.job(5, nextRunAt: Sample.stamp(1)),
            Sample.job(6, dependsOn: [Sample.id(7)]),
            Sample.job(7, state: .running),
            Sample.job(8, dependsOn: [Sample.id(9)]),
            Sample.job(9, state: .succeeded)
        ]
        let picked = JobPicker.pick(from: jobs, for: Sample.macbook, capacity: roomy, now: Sample.time(5)).map(\.id)
        #expect(picked == [Sample.id(1), Sample.id(5), Sample.id(8)])
    }

    @Test func respectsCapacityWithRunningJobs() {
        let jobs = [
            Sample.job(1, state: .running, needs: .init(claude: true, build: false)),
            Sample.job(2, needs: .init(claude: true, build: true)),
            Sample.job(3, needs: .init(claude: false, build: true)),
            Sample.job(4, needs: .init(claude: false, build: false)),
            Sample.job(5, needs: .init(claude: false, build: true))
        ]
        let capacity = MacFile.Capacity(claude: 1, build: 1)
        let picked = JobPicker.pick(from: jobs, for: Sample.macbook, capacity: capacity, now: Sample.time(0)).map(\.id)
        #expect(picked == [Sample.id(3), Sample.id(4)])
    }

    @Test func peopleWaitingComeFirst() {
        let jobs = [
            Sample.job(1, kind: .implementTask, createdMinute: 0),
            Sample.job(2, kind: .cleanUp, createdMinute: 0),
            Sample.job(3, kind: .fixFinalPullRequest, createdMinute: 2),
            Sample.job(4, kind: .explain, createdMinute: 3),
            Sample.job(5, kind: .makeQuestions, createdMinute: 1),
            Sample.job(6, kind: .implementTask, createdMinute: -1)
        ]
        let capacity = MacFile.Capacity(claude: 10, build: 10)
        let picked = JobPicker.pick(from: jobs, for: Sample.macbook, capacity: capacity, now: Sample.time(5)).map(\.id)
        #expect(picked == [Sample.id(4), Sample.id(5), Sample.id(3), Sample.id(6), Sample.id(1), Sample.id(2)])
    }

    @Test func everyKindHasAPriority() {
        #expect(Set(JobKind.allCases.map(JobPicker.priority)).isSubset(of: 0...4))
    }
}
