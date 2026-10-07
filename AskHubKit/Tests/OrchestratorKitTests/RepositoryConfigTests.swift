@testable import OrchestratorKit
import Testing

struct RepositoryConfigTests {
    @Test(arguments: [
        ("/src/ask-hub-apple", "/src/ask-hub-apple-ralph-ctl"),
        // scripts/ralph-setup.sh と同じく、ディレクトリ名の末尾の -ios は除く
        ("/src/ninjacord-ios", "/src/ninjacord-ralph-ctl"),
        ("/src/ios-app", "/src/ios-app-ralph-ctl")
    ])
    func controlWorktreeIsNextToCheckout(checkoutPath: String, expected: String) {
        let repository = RepositoryConfig(owner: "shilokuma-inc", name: "app", checkoutPath: checkoutPath)
        #expect(repository.controlWorktreePath == expected)
    }

    @Test func findsRepositoryIgnoringCase() throws {
        let repository = RepositoryConfig(owner: "shilokuma-inc", name: "ask-hub-apple", checkoutPath: "/src/ask-hub-apple")
        let config = OrchestratorConfig(
            trustedAuthorLogins: ["mrs1669"],
            repositories: [repository],
            pollInterval: .seconds(60),
            loopCommand: try LoopCommandTemplate(arguments: ["start"])
        )
        #expect(config.repository(named: "Shilokuma-Inc/Ask-Hub-Apple") == repository)
        #expect(config.repository(named: "shilokuma-inc/other") == nil)
    }
}
