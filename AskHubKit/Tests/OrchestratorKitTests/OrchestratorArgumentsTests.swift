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
        #expect(
            try OrchestratorArguments.parse(["--once", "--config", "/tmp/a.json"])
                == OrchestratorArguments(configPath: "/tmp/a.json", runsOnce: true)
        )
    }

    @Test func rejectsMissingValueAndUnknownOption() {
        #expect(throws: OrchestratorArguments.ArgumentError.missingValue(option: "--config")) {
            try OrchestratorArguments.parse(["--config"])
        }
        #expect(throws: OrchestratorArguments.ArgumentError.unknownOption("--verbose")) {
            try OrchestratorArguments.parse(["--verbose"])
        }
    }

    @Test func parsesExtractZipCommand() throws {
        #expect(
            try OrchestratorArguments.parse(["extract-zip", "/tmp/a.zip", "/tmp/out"])
                == OrchestratorArguments(extractZip: .init(zipPath: "/tmp/a.zip", destinationPath: "/tmp/out"))
        )
        // パスが - で始まってもオプションとして読まない
        #expect(
            try OrchestratorArguments.parse(["extract-zip", "--once", "-x"]).extractZip
                == .init(zipPath: "--once", destinationPath: "-x")
        )
        #expect(try OrchestratorArguments.parse(["extract-zip", "--help"]) == OrchestratorArguments(showsHelp: true))
        #expect(try OrchestratorArguments.parse(["extract-zip", "-h"]) == OrchestratorArguments(showsHelp: true))
    }

    @Test func rejectsExtractZipWithWrongArguments() {
        let expected = OrchestratorArguments.ArgumentError.invalidArguments(command: "extract-zip", expected: "<zip> <展開先>")
        let invalid = [["extract-zip"], ["extract-zip", "/tmp/a.zip"], ["extract-zip", "/tmp/a.zip", ""], ["extract-zip", "a", "b", "c"]]
        for arguments in invalid {
            #expect(throws: expected) {
                try OrchestratorArguments.parse(arguments)
            }
        }
        // サブコマンドは先頭にあるときだけ。オプションの後ろでは今までどおり未知の引数
        #expect(throws: OrchestratorArguments.ArgumentError.unknownOption("extract-zip")) {
            try OrchestratorArguments.parse(["--once", "extract-zip", "a", "b"])
        }
    }
}
