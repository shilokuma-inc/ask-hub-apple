import AskHubProtocol
import Foundation

/// テストで使うジョブ・試行・Mac の印
enum Fixtures {
    static let repo = RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!
    static let epic = ULID(rawValue: "01JCEP1C000000000000000001")!
    static let macbook = MacName(rawValue: "macbook-a")!
    static let macMini = MacName(rawValue: "mac-mini")!
    static let start = Date(timeIntervalSince1970: 1_793_700_000)

    static func id(_ number: Int) -> ULID {
        ULID(rawValue: "01JCJ0B" + String(format: "%019d", number))!
    }

    static func time(_ minutes: Double) -> Date {
        start.addingTimeInterval(minutes * 60)
    }

    static func stamp(_ minutes: Double) -> Timestamp {
        Timestamp(time(minutes))
    }

    static func job(
        _ number: Int = 1,
        kind: JobKind = .implementTask,
        mac: MacName? = macbook,
        state: JobState = .assigned,
        attempts: Int = 0,
        needs: JobFile.Needs = JobFile.Needs(claude: true, build: true),
        dependsOn: [ULID] = [],
        nextRunAt: Timestamp? = nil,
        createdMinute: Double = 0
    ) -> JobFile {
        JobFile(
            id: id(number),
            kind: kind,
            repo: repo,
            epic: epic,
            assignedMac: mac,
            needs: needs,
            dependsOn: dependsOn,
            state: state,
            attempts: attempts,
            nextRunAt: nextRunAt,
            createdAt: stamp(createdMinute),
            updatedAt: stamp(createdMinute)
        )
    }

    static func attempt(
        job: Int = 1,
        _ number: Int,
        mac: MacName = macbook,
        startedMinute: Double = 0,
        heartbeatMinute: Double? = nil,
        failure: FailureClass? = nil,
        succeeded: Bool = false,
        retryAt: Timestamp? = nil
    ) -> AttemptFile {
        let ended = failure != nil || succeeded
        let heartbeat = heartbeatMinute ?? startedMinute
        return AttemptFile(
            job: id(job),
            number: number,
            mac: mac,
            startedAt: stamp(startedMinute),
            heartbeatAt: stamp(heartbeat),
            endedAt: ended ? stamp(heartbeat) : nil,
            outcome: failure != nil ? .failed : (succeeded ? .succeeded : .running),
            failure: failure.map { AttemptFailure(failureClass: $0, message: "テスト", retryAt: retryAt) }
        )
    }

    static func mac(_ name: MacName = macbook, seenMinute: Double) -> MacFile {
        MacFile(
            mac: name,
            kind: .resident,
            seenAt: stamp(seenMinute),
            versions: MacFile.Versions(worker: "1.0.0"),
            diskFreeGB: 100,
            load: 1,
            capacity: MacFile.Capacity(claude: 2, build: 1),
            selfCheck: SelfCheck(checkedAt: stamp(0), keychain: .ok, githubToken: .ok, claudeToken: .ok)
        )
    }
}
