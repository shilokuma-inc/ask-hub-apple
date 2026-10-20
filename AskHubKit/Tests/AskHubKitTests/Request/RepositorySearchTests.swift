import AskHubKit
import Testing

struct RepositorySearchTests {
    private let repositories = [
        "shilokuma-inc/ask-hub-apple",
        "shilokuma-inc/notti-ios",
        "shilokuma-labs/web_tools",
        "Other/AskHub"
    ]

    @Test func matchesRepositoryNameIgnoringCaseSeparatorsAndSpaces() {
        #expect(RepositorySearch.filter(repositories, matching: "ask hub apple") == ["shilokuma-inc/ask-hub-apple"])
        #expect(RepositorySearch.filter(repositories, matching: "Ask_Hub-Apple") == ["shilokuma-inc/ask-hub-apple"])
        #expect(RepositorySearch.filter(repositories, matching: "webtools") == ["shilokuma-labs/web_tools"])
        #expect(RepositorySearch.filter(repositories, matching: "web tools") == ["shilokuma-labs/web_tools"])
    }

    @Test func matchesPartOfTheNameKeepingOrder() {
        #expect(RepositorySearch.filter(repositories, matching: "askhub") == ["shilokuma-inc/ask-hub-apple", "Other/AskHub"])
        #expect(RepositorySearch.filter(repositories, matching: "ios") == ["shilokuma-inc/notti-ios"])
    }

    @Test func matchesOwnerAndFullName() {
        #expect(RepositorySearch.filter(repositories, matching: "shilokuma inc/notti ios") == ["shilokuma-inc/notti-ios"])
        #expect(RepositorySearch.filter(repositories, matching: "shilokuma labs") == ["shilokuma-labs/web_tools"])
    }

    @Test func returnsNothingForEmptyOrUnknownQuery() {
        for query in ["", " - _ ", "dotfiles"] {
            let found = RepositorySearch.filter(repositories, matching: query)
            #expect(found.isEmpty, "\(query)")
        }
    }

    @Test func doesNotIgnoreDots() {
        #expect(RepositorySearch.filter(["o/site.github.io", "o/sitegithubio"], matching: "site.github") == ["o/site.github.io"])
    }
}
