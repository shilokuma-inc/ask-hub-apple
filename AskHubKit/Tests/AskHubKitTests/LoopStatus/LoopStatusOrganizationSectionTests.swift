@testable import AskHubKit
import Foundation
import Testing

/// ステータスタブのリポジトリの行を organization ごとの節にまとめる
struct LoopStatusOrganizationSectionTests {
    private func row(_ repository: String) -> LoopStatusRow {
        LoopStatusRow(repository: repository, report: nil)
    }

    private func repositories(_ sections: [LoopStatusOrganizationSection]) -> [[String]] {
        sections.map { $0.rows.map(\.repository) }
    }

    @Test func groupsRowsByOwnerKeepingOrder() {
        let rows = ["alpha/a", "alpha/b", "beta/a", "beta/c", "gamma/z"].map(row)
        let sections = LoopStatusOrganizationSection.sections(from: rows)
        #expect(sections.map(\.organization) == ["alpha", "beta", "gamma"])
        #expect(repositories(sections) == [["alpha/a", "alpha/b"], ["beta/a", "beta/c"], ["gamma/z"]])
    }

    @Test func singleOrganizationStillMakesOneSection() {
        let sections = LoopStatusOrganizationSection.sections(from: ["shilokuma-inc/a", "shilokuma-inc/b"].map(row))
        #expect(sections.map(\.organization) == ["shilokuma-inc"])
        #expect(repositories(sections) == [["shilokuma-inc/a", "shilokuma-inc/b"]])
    }

    @Test func emptyRowsMakeNoSection() {
        #expect(LoopStatusOrganizationSection.sections(from: []).isEmpty)
    }

    /// login は大文字小文字を区別しないので同じ節にまとめ、見出しは最初の行の owner をそのまま出す
    @Test func ownersDifferingOnlyInCaseShareSection() {
        let rows = ["Shilokuma-Inc/a", "shilokuma-inc/b", "zeta/c"].map(row)
        let sections = LoopStatusOrganizationSection.sections(from: rows)
        #expect(sections.map(\.organization) == ["Shilokuma-Inc", "zeta"])
        #expect(sections.map(\.id) == ["shilokuma-inc", "zeta"])
        #expect(repositories(sections) == [["Shilokuma-Inc/a", "shilokuma-inc/b"], ["zeta/c"]])
    }

    /// 並びの途中で owner が戻ってきても、最初に出てきた節に入れる（節が重複しない）
    @Test func ownerAppearingAgainJoinsFirstSection() {
        let sections = LoopStatusOrganizationSection.sections(from: ["alpha/a", "beta/b", "alpha/c"].map(row))
        #expect(sections.map(\.organization) == ["alpha", "beta"])
        #expect(repositories(sections) == [["alpha/a", "alpha/c"], ["beta/b"]])
    }

    @Test func repositoryWithoutSlashIsItsOwnOwner() {
        #expect(LoopStatusOrganizationSection.owner(of: "lonely") == "lonely")
        #expect(LoopStatusOrganizationSection.owner(of: "o/r") == "o")
    }
}
