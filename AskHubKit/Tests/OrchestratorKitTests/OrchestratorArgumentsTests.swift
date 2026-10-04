@testable import OrchestratorKit
import Testing

struct OrchestratorArgumentsTests {
    @Test func defaultsWithoutArguments() throws {
        #expect(try OrchestratorArguments.parse([]) == OrchestratorArguments())
    }

    @Test func parsesConfigPathAndHelp() throws {
        #expect(try OrchestratorArguments.parse(["--config", "/tmp/a.json"]) == OrchestratorArguments(configPath: "/tmp/a.json"))
        #expect(try OrchestratorArguments.parse(["-h"]).showsHelp)
        #expect(try OrchestratorArguments.parse(["--help"]).showsHelp)
    }

    @Test func rejectsMissingValueAndUnknownOption() {
        #expect(throws: OrchestratorArguments.ArgumentError.missingValue(option: "--config")) {
            try OrchestratorArguments.parse(["--config"])
        }
        #expect(throws: OrchestratorArguments.ArgumentError.unknownOption("--verbose")) {
            try OrchestratorArguments.parse(["--verbose"])
        }
    }
}
