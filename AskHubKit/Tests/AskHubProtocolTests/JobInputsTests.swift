@testable import AskHubProtocol
import Foundation
import Testing

/// 段階 3 のジョブの入力を、書いた形のまま読めることと、形が違う入力を読まないこと
struct JobInputsTests {
    static let head = String(repeating: "a", count: 40)

    private func job(input: [String: JSONValue]?) -> JobFile {
        let time = Timestamp(rawValue: "2026-11-07T10:00:00Z")!
        return JobFile(
            id: ULID(rawValue: "01JCJ0B0000000000000000001")!,
            kind: .reviewTask,
            repo: RepositoryFullName(rawValue: "shilokuma-inc/askhub-sandbox")!,
            epic: ULID(rawValue: "01JCEP1C000000000000000001")!,
            task: "t1",
            needs: .init(claude: true, build: true),
            state: .assigned,
            input: input,
            createdAt: time,
            updatedAt: time
        )
    }

    @Test func roundTrips() {
        let review = PullRequestInput(pullRequest: 41, head: Self.head)
        #expect(review.jobInput == ["pullRequest": .integer(41), "head": .string(Self.head)])
        #expect(job(input: review.jobInput).input(as: PullRequestInput.self) == review)
        let fix = FixTaskInput(pullRequest: 41, head: Self.head, reason: .review)
        #expect(job(input: fix.jobInput).input(as: FixTaskInput.self) == fix)
        let rerun = RerunChecksInput(pullRequest: 41, head: Self.head, runs: [42_247_314_557])
        #expect(job(input: rerun.jobInput).input(as: RerunChecksInput.self) == rerun)
        let integrate = IntegrateBaseInput(base: Self.head)
        #expect(job(input: integrate.jobInput).input(as: IntegrateBaseInput.self) == integrate)
    }

    @Test func refusesMalformedInputs() {
        let cases: [[String: JSONValue]?] = [
            nil,
            [:],
            ["pullRequest": .integer(0), "head": .string(Self.head)],
            ["pullRequest": .integer(41), "head": .string("main")],
            ["pullRequest": .integer(41), "head": .string(String(repeating: "A", count: 40))],
            ["pullRequest": .string("41"), "head": .string(Self.head)]
        ]
        for input in cases {
            #expect(job(input: input).input(as: PullRequestInput.self) == nil, "\(String(describing: input))")
        }
        let unknownReason: [String: JSONValue] = ["pullRequest": .integer(41), "head": .string(Self.head), "reason": .string("lint")]
        #expect(job(input: unknownReason).input(as: FixTaskInput.self) == nil)
        #expect(job(input: RerunChecksInput(pullRequest: 41, head: Self.head, runs: []).jobInput).input(as: RerunChecksInput.self) == nil)
        #expect(job(input: ["base": .string("develop")]).input(as: IntegrateBaseInput.self) == nil)
    }
}
