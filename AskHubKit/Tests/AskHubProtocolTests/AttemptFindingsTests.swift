@testable import AskHubProtocol
import Foundation
import Testing

struct AttemptFindingsTests {
    static func attempt(findings: String) -> AttemptFile {
        let time = Timestamp(rawValue: "2026-11-07T10:00:00Z")!
        return AttemptFile(
            job: ULID(rawValue: "01JCJ0B0000000000000000002")!,
            number: 1,
            mac: MacName(rawValue: "macbook-a")!,
            startedAt: time,
            heartbeatAt: time,
            endedAt: time,
            outcome: .succeeded,
            outputs: AttemptFile.Outputs(pullRequest: 41, verdict: .fixReview, findings: findings)
        )
    }

    @Test func countsFindingsLengthInCodePointsLikeJSONSchema() {
        let limit = AttemptFile.Outputs.maximumFindingsLength
        #expect(Self.attempt(findings: String(repeating: "あ", count: limit)).violations.isEmpty)
        // 結合文字（e + U+0301）は 1 文字（書記素）でも、JSON Schema の maxLength では 2 つと数える
        let combining = String(repeating: "e\u{301}", count: limit / 2 + 1)
        #expect(combining.count <= limit)
        #expect(Self.attempt(findings: combining).violations.contains { $0.hasPrefix("outputs.findings") })
    }
}
