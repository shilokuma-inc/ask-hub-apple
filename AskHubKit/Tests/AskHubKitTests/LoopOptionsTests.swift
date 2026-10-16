@testable import AskHubKit
import Foundation
import Testing

struct LoopOptionsTests {
    @Test func roundTripsOptionsThroughComment() {
        let options = LoopOptions(model: .sonnet, effort: .high)

        #expect(options.comment.hasPrefix(#"<!-- ask-hub:loop-options model="claude-sonnet-5-5" effort="high" -->"#))
        #expect(options.comment.contains("Sonnet 5.5・エフォート high"))
        #expect(LoopOptions.parse(options.comment) == options)
    }

    @Test func omitsUnspecifiedValues() {
        let effortOnly = LoopOptions(effort: .xhigh)

        #expect(effortOnly.comment.hasPrefix(#"<!-- ask-hub:loop-options effort="xhigh" -->"#))
        #expect(LoopOptions.parse(effortOnly.comment) == effortOnly)
        #expect(LoopOptions(model: .opus).comment.hasPrefix(#"<!-- ask-hub:loop-options model="claude-opus-5-5" -->"#))
        #expect(LoopOptions().isDefault)
        #expect(!effortOnly.isDefault)
    }

    @Test func ignoresMarkersNotAtStartOrWithOtherKeyword() {
        for body in [
            "モデルは Opus にしたい",
            #"前置き <!-- ask-hub:loop-options model="claude-opus-5-5" -->"#,
            #"<!-- ask-hub:loop-optionsX model="claude-opus-5-5" -->"#,
            #"<!-- ask-hub:loop-options model="claude-opus-5-5""#
        ] {
            #expect(LoopOptions.parse(body) == nil, "\(body)")
        }
    }

    @Test func treatsUnknownValuesAsUnspecified() {
        let parsed = LoopOptions.parse(#"  <!-- ask-hub:loop-options model="gpt-5" effort="ultra" -->"#)

        #expect(parsed == LoopOptions())
    }

    @Test func usesLatestMarkerFromTrustedAuthor() {
        let trusted = TrustedAuthors(["mrs1669", "partner"])
        let comments: [(author: String?, body: String)] = [
            ("mrs1669", LoopOptions(model: .fable).comment),
            ("Partner", LoopOptions(model: .sonnet, effort: .low).comment),
            ("stranger", LoopOptions(model: .opus, effort: .max).comment),
            (nil, LoopOptions(effort: .max).comment),
            ("mrs1669", "ありがとうございます")
        ]

        #expect(LoopOptions.latest(in: comments, trustedAuthors: trusted) == LoopOptions(model: .sonnet, effort: .low))
        #expect(LoopOptions.latest(in: [("stranger", LoopOptions(model: .opus).comment)], trustedAuthors: trusted) == nil)
    }
}
