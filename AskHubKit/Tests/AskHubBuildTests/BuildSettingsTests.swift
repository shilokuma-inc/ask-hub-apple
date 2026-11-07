@testable import AskHubBuild
import Foundation
import Testing

struct BuildSettingsTests {
    static let json = """
    {
      "project": "AskHub.xcodeproj",
      "scheme": "AskHub",
      "destinations": [
        {"platform": "iOS", "deviceType": "iPhone 17 Pro", "osVersion": "26.5"},
        {"platform": "visionOS", "deviceType": "Apple Vision Pro"},
        {"platform": "macOS"}
      ],
      "pullRequestTests": {"onlyTesting": ["AskHubTests"]},
      "finalTests": {"testPlan": "Full", "skipTesting": ["AskHubUITests/AskHubUITestsLaunchTests"]}
    }
    """

    private func decode(_ json: String) throws -> BuildSettings {
        try JSONDecoder().decode(BuildSettings.self, from: Data(json.utf8))
    }

    @Test func decodesAndEncodesTheSettings() throws {
        let settings = try decode(Self.json)
        #expect(settings.project == "AskHub.xcodeproj")
        #expect(settings.projectOption == "-project")
        #expect(settings.destinations == [
            .simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro", osVersion: "26.5")),
            .simulator(SimulatorDestination(platform: .visionOS, deviceType: "Apple Vision Pro")),
            .macOS
        ])
        #expect(settings.tests(for: .pullRequest) == TestSelection(onlyTesting: ["AskHubTests"]))
        #expect(settings.tests(for: .finalPullRequest) == TestSelection(
            testPlan: "Full", skipTesting: ["AskHubUITests/AskHubUITestsLaunchTests"]
        ))
        let again = try JSONDecoder().decode(BuildSettings.self, from: JSONEncoder().encode(settings))
        #expect(again == settings)
    }

    @Test func defaultsTheTestsToEverything() throws {
        let settings = try decode(#"{"project": "App.xcworkspace", "scheme": "App", "destinations": [{"platform": "macOS"}]}"#)
        #expect(settings.projectOption == "-workspace")
        #expect(settings.pullRequestTests == TestSelection())
        #expect(settings.finalTests == TestSelection())
    }

    /// 作れなかったときの、誤りの欄
    private func refusedField(_ make: () throws -> BuildSettings) -> String? {
        do {
            _ = try make()
            return nil
        } catch let error as BuildSettingsError {
            return error.field
        } catch {
            return "\(error)"
        }
    }

    @Test(arguments: [
        "../Other/App.xcodeproj", "App/../../App.xcodeproj", "/Users/me/App.xcodeproj", "~/App.xcodeproj", "-project.xcodeproj",
        "App//App.xcodeproj", "App.xcodeproj\n", "Package.swift", ""
    ])
    func refusesUnsafeProjectPaths(project: String) {
        #expect(refusedField { try BuildSettings(project: project, scheme: "App", destinations: [.macOS]) } == "project")
    }

    @Test func acceptsProjectsInSubdirectories() {
        #expect(refusedField { try BuildSettings(project: "App/App.xcodeproj", scheme: "App", destinations: [.macOS]) } == nil)
        #expect(refusedField { try BuildSettings(project: "./App.xcworkspace", scheme: "App", destinations: [.macOS]) } == nil)
    }

    @Test func refusesValuesThatWouldBeReadAsOptions() {
        let iPhone = BuildDestination.simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro"))
        #expect(refusedField { try BuildSettings(project: "A.xcodeproj", scheme: "-quiet", destinations: [.macOS]) } == "scheme")
        #expect(refusedField { try BuildSettings(project: "A.xcodeproj", scheme: "A", destinations: []) } == "destinations")
        #expect(refusedField { try BuildSettings(project: "A.xcodeproj", scheme: "A", destinations: [.macOS, .macOS]) } == "destinations")
        let option = BuildDestination.simulator(SimulatorDestination(platform: .iOS, deviceType: "-x"))
        #expect(refusedField { try BuildSettings(project: "A.xcodeproj", scheme: "A", destinations: [option]) }
            == "destinations.deviceType")
        let version = BuildDestination.simulator(SimulatorDestination(platform: .iOS, deviceType: "iPhone", osVersion: "26.x"))
        #expect(refusedField { try BuildSettings(project: "A.xcodeproj", scheme: "A", destinations: [version]) }
            == "destinations.osVersion")
        let onlyTesting = TestSelection(onlyTesting: ["-x"])
        #expect(refusedField {
            try BuildSettings(project: "A.xcodeproj", scheme: "A", destinations: [iPhone], pullRequestTests: onlyTesting)
        } == "pullRequestTests.onlyTesting")
        #expect(refusedField {
            try BuildSettings(project: "A.xcodeproj", scheme: "A", destinations: [iPhone], finalTests: TestSelection(testPlan: "-x"))
        } == "finalTests.testPlan")
    }

    @Test func refusesBrokenSettingsWhenDecoding() {
        let broken = [
            #"{"project": "../A.xcodeproj", "scheme": "A", "destinations": [{"platform": "macOS"}]}"#,
            #"{"project": "A.xcodeproj", "scheme": "A", "destinations": [{"platform": "watchOS", "deviceType": "Apple Watch"}]}"#,
            #"{"project": "A.xcodeproj", "scheme": "A", "destinations": [{"platform": "iOS"}]}"#,
            #"{"project": "A.xcodeproj", "scheme": "A", "destinations": [{"platform": "macOS"}], "finalTests": {"skipTesting": ["-x"]}}"#
        ]
        for json in broken {
            #expect(throws: DecodingError.self, "\(json)") { try decode(json) }
        }
    }
}
