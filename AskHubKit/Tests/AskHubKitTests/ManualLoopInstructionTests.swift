@testable import AskHubKit
import Foundation
import Testing

struct ManualLoopInstructionTests {
    @Test func instructsToUseManualScript() {
        let start = ManualLoopInstruction.start(repository: "shilokuma-inc/notti-ios", discussionNumber: 12)
        let resume = ManualLoopInstruction.resume(repository: "shilokuma-inc/notti-ios", discussionNumber: 12)

        #expect(start.hasPrefix("shilokuma-inc/notti-ios で Discussion #12 の epic を手動ループで回して"))
        #expect(start.contains("scripts/askhub-manual.sh"))
        #expect(resume.contains("Discussion #12 の手動ループを再開して"))
        #expect(resume.contains("scripts/askhub-manual.sh resume"))
        let final = ManualLoopInstruction.final(repository: "shilokuma-inc/notti-ios", discussionNumber: 12)
        #expect(final.contains("Discussion #12 の手動ループの最終 PR を作って"))
        #expect(final.contains("scripts/askhub-manual.sh final"))
    }

    @Test func roundTripsAssigneeThroughComment() {
        let body = ManualLoopAssignment.comment(assignee: "partner", repository: "shilokuma-inc/notti-ios", discussionNumber: 12)

        #expect(body.hasPrefix(#"<!-- ask-hub:manual-assignee login="partner" -->"#))
        // 担当者に GitHub の通知が届くよう @メンションする
        #expect(body.contains("@partner さんが"))
        #expect(body.contains(ManualLoopInstruction.start(repository: "shilokuma-inc/notti-ios", discussionNumber: 12)))
        #expect(ManualLoopAssignment.assignee(in: body) == "partner")
    }

    @Test func ignoresMalformedOrUntrustedAssignments() {
        for body in [
            "担当は partner です",
            #"前置き <!-- ask-hub:manual-assignee login="partner" -->"#,
            #"<!-- ask-hub:manual-assignee login="part ner" -->"#,
            #"<!-- ask-hub:manual-assignee login="-partner" -->"#,
            #"<!-- ask-hub:manual-assignee login="partner"-->"#
        ] {
            #expect(ManualLoopAssignment.assignee(in: body) == nil, "\(body)")
        }

        let comments: [(author: String?, body: String)] = [
            ("mrs1669", ManualLoopAssignment.comment(assignee: "mrs1669", repository: "o/r", discussionNumber: 1)),
            ("mrs1669", ManualLoopAssignment.comment(assignee: "partner", repository: "o/r", discussionNumber: 1)),
            // 信用外の author が担当者を書き換えようとしても無視する
            ("someone", ManualLoopAssignment.comment(assignee: "someone", repository: "o/r", discussionNumber: 1)),
            ("mrs1669", "了解です")
        ]
        #expect(ManualLoopAssignment.latestAssignee(in: comments, trustedAuthors: TrustedAuthors(["mrs1669"])) == "partner")
    }
}
