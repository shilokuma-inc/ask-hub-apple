import Foundation
@testable import OrchestratorKit
import Testing

struct BuildHostsConfigTests {
    private let loader = OrchestratorConfigLoader(homeDirectory: "/Users/tester")

    private func decode(buildHosts: String?) throws(OrchestratorConfigError) -> OrchestratorConfig {
        var fields = [
            #""repositories": [{ "repository": "shilokuma-inc/ask-hub-apple", "path": "~/src/ask-hub-apple" }]"#,
            #""loopCommand": ["/usr/local/bin/start-loop"]"#
        ]
        if let buildHosts {
            fields.append(#""buildHosts": \#(buildHosts)"#)
        }
        return try loader.decode(Data(("{" + fields.joined(separator: ",") + "}").utf8))
    }

    @Test func turnsOffWithoutKey() throws {
        #expect(try decode(buildHosts: nil).buildHosts == nil)
    }

    @Test func readsPathsAndRepository() throws {
        let config = try decode(
            buildHosts: #"{ "xcb": "~/.config/askhub/xcodebuild", "issueRepository": " shilokuma-inc/ask-hub-apple " }"#
        )
        #expect(config.buildHosts == BuildHostsConfig(
            xcbPath: "/Users/tester/.config/askhub/xcodebuild",
            eventsDirectory: "/Users/tester/Library/Logs/askhub/xcb",
            issueRepository: "shilokuma-inc/ask-hub-apple"
        ))

        let custom = try decode(buildHosts: #"{ "xcb": "/opt/xcb", "eventsDirectory": "/var/log/xcb/" }"#)
        #expect(custom.buildHosts == BuildHostsConfig(xcbPath: "/opt/xcb", eventsDirectory: "/var/log/xcb"))
    }

    @Test func rejectsRelativePathsAndMalformedRepository() {
        #expect(throws: OrchestratorConfigError.relativeBuildHostsPath(key: "buildHosts.xcb", path: "xcb")) {
            try decode(buildHosts: #"{ "xcb": "xcb" }"#)
        }
        #expect(throws: OrchestratorConfigError.relativeBuildHostsPath(key: "buildHosts.eventsDirectory", path: "logs")) {
            try decode(buildHosts: #"{ "xcb": "/opt/xcb", "eventsDirectory": "logs" }"#)
        }
        #expect(throws: OrchestratorConfigError.invalidBuildHostsRepository("ask-hub-apple")) {
            try decode(buildHosts: #"{ "xcb": "/opt/xcb", "issueRepository": "ask-hub-apple" }"#)
        }
        #expect(throws: OrchestratorConfigError.self) {
            try decode(buildHosts: #"{ "issueRepository": "shilokuma-inc/ask-hub-apple" }"#)
        }
    }

    @Test func usesIssueRepositoryOnlyWhileAssigned() throws {
        let config = try decode(buildHosts: #"{ "xcb": "/opt/xcb", "issueRepository": "Shilokuma-Inc/Ask-Hub-Apple" }"#)
        let buildHosts = try #require(config.buildHosts)
        #expect(buildHosts.issueRepository(in: config)?.fullName == "shilokuma-inc/ask-hub-apple")

        // 担当から外したリポジトリを指していても、設定ファイルは読める（Issue は書かない）
        let removed = try decode(buildHosts: #"{ "xcb": "/opt/xcb", "issueRepository": "shilokuma-inc/other" }"#)
        #expect(removed.buildHosts.map { $0.issueRepository(in: removed) } == .some(nil))
        #expect(BuildHostsConfig(xcbPath: "/opt/xcb", eventsDirectory: "/tmp").issueRepository(in: config) == nil)
    }
}
