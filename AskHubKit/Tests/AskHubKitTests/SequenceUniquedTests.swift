@testable import AskHubKit
import Testing

struct SequenceUniquedTests {
    @Test func keepsFirstElementOfEachKeyInOrder() {
        let pairs = [("b", 1), ("a", 2), ("b", 3), ("c", 4), ("a", 5)]
        let uniqued = pairs.uniqued(by: \.0)
        #expect(uniqued.map(\.0) == ["b", "a", "c"])
        #expect(uniqued.map(\.1) == [1, 2, 4])
    }

    @Test func comparesByTheGivenKey() {
        let names = ["Shilokuma-Inc/App", "shilokuma-inc/app", "shilokuma-inc/other"]
        #expect(names.uniqued(by: { $0.lowercased() }) == ["Shilokuma-Inc/App", "shilokuma-inc/other"])
        #expect(names.uniqued(by: \.self) == names)
        #expect([String]().uniqued(by: \.self).isEmpty)
    }
}
