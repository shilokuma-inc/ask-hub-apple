import AskHubKit
import Foundation
import Testing

struct CIFixMarkerTests {
    private static let sha = String(repeating: "a", count: 40)

    @Test func roundTripsAfterOrchestratorMarker() throws {
        for action in CIFixMarker.Action.allCases {
            let marker = CIFixMarker(action: action, sha: Self.sha.uppercased())
            let comment = try #require(marker.htmlComment)
            #expect(comment == "<!-- ask-hub:ci-fix action=\"\(action.rawValue)\" sha=\"\(Self.sha)\" -->")
            #expect(CIFixMarker.parse("\(FinalPullRequestMarker.orchestrator)\n\(comment)\n本文") == marker)
            #expect(CIFixMarker.parse("  \n\(comment)") == marker)
        }
    }

    @Test func ignoresBodiesWithoutLeadingMarker() {
        let comment = CIFixMarker(action: .attempt, sha: Self.sha).htmlComment ?? ""
        #expect(CIFixMarker.parse("本文\n\(comment)") == nil)
        #expect(CIFixMarker.parse(#"<!-- ask-hub:ci-fix action="retry" sha="\#(Self.sha)" -->"#) == nil)
        #expect(CIFixMarker.parse(#"<!-- ask-hub:ci-fix action="attempt" -->"#) == nil)
        #expect(CIFixMarker.parse(#"<!-- ask-hub:ci-fixes action="attempt" sha="\#(Self.sha)" -->"#) == nil)
    }

    @Test func recordsAttemptsCancelsAndGiveUp() {
        let other = String(repeating: "b", count: 40)
        let record = CIFixRecord(markers: [
            CIFixMarker(action: .attempt, sha: Self.sha),
            CIFixMarker(action: .attempt, sha: Self.sha),
            CIFixMarker(action: .attempt, sha: other),
            CIFixMarker(action: .cancel, sha: other)
        ])
        #expect(record == CIFixRecord(attemptedSHAs: [Self.sha]))
        #expect(record.attempted(Self.sha.uppercased()))
        #expect(!record.attempted(other))
        #expect(CIFixRecord(markers: [CIFixMarker(action: .gaveUp, sha: other)]).gaveUp)
    }
}
