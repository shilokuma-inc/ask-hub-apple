@testable import AskHub
import AskHubKit
import Foundation
import Testing

@MainActor
struct OrganizationSettingsModelTests {
    /// テストごとに空の UserDefaults を使う
    private static func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "OrganizationSettingsModelTests-\(UUID().uuidString)")!
    }

    @Test func usesDefaultOrganizationWhenNothingIsSaved() {
        let defaults = Self.makeDefaults()
        #expect(OrganizationSettings.load(from: defaults) == TargetOrganizations.defaultLogins)
        // 使えない値しか残っていなければ既定に戻す
        defaults.set(["org:x", " "], forKey: OrganizationSettings.defaultsKey)
        #expect(OrganizationSettings.load(from: defaults) == TargetOrganizations.defaultLogins)
    }

    @Test func addsTrimmedLoginAndSavesIt() {
        let defaults = Self.makeDefaults()
        let model = OrganizationSettingsModel(defaults: defaults)
        model.input = " BeaconFun4 \n"
        #expect(model.canAdd)
        model.add()
        #expect(model.logins == ["shilokuma-inc", "BeaconFun4"])
        #expect(model.input.isEmpty)
        #expect(OrganizationSettings.load(from: defaults) == ["shilokuma-inc", "BeaconFun4"])
    }

    @Test func rejectsInvalidOrDuplicateLogin() {
        let model = OrganizationSettingsModel(defaults: Self.makeDefaults())
        for input in ["", "org:other", "shilokuma inc", "Shilokuma-Inc"] {
            model.input = input
            #expect(!model.canAdd)
            model.add()
        }
        #expect(model.logins == ["shilokuma-inc"])
    }

    @Test func keepsLastOrganization() {
        let defaults = Self.makeDefaults()
        let model = OrganizationSettingsModel(defaults: defaults)
        model.input = "BeaconFun4"
        model.add()
        model.remove("shilokuma-inc")
        #expect(model.logins == ["BeaconFun4"])
        #expect(!model.canRemove)
        model.remove("BeaconFun4")
        #expect(model.logins == ["BeaconFun4"])
        #expect(OrganizationSettings.load(from: defaults) == ["BeaconFun4"])
    }
}
