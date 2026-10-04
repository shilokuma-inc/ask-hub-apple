import AskHubKit
import Testing

struct RepositorySectionTests {
    @Test func groupsAppsFirstKeepingOrder() {
        let sections = RepositorySection.grouping([
            "shilokuma-inc/dotfiles",
            "shilokuma-inc/ask-hub-apple",
            "shilokuma-inc/template-app-ios",
            "shilokuma-inc/Notti-iOS",
            "shilokuma-inc/ios-tools"
        ])

        #expect(sections == [
            RepositorySection(
                title: "アプリ",
                repositories: ["shilokuma-inc/ask-hub-apple", "shilokuma-inc/template-app-ios", "shilokuma-inc/Notti-iOS"]
            ),
            RepositorySection(title: "その他", repositories: ["shilokuma-inc/dotfiles", "shilokuma-inc/ios-tools"])
        ])
    }

    @Test func omitsEmptySections() {
        #expect(RepositorySection.grouping([]).isEmpty)
        #expect(RepositorySection.grouping(["o/dotfiles"]) == [RepositorySection(title: "その他", repositories: ["o/dotfiles"])])
        #expect(RepositorySection.grouping(["o/notti-ios"]) == [RepositorySection(title: "アプリ", repositories: ["o/notti-ios"])])
    }
}
