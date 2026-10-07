import AskHubKit
import Testing

struct TargetOrganizationsTests {
    @Test(arguments: ["shilokuma-inc", "BeaconFun4", "a", String(repeating: "a", count: 39)])
    func acceptsLogin(_ login: String) {
        #expect(TargetOrganizations.isValid(login))
    }

    @Test(arguments: [
        "", " ", "-org", "shilokuma inc", "org:other", "a/b", "org\n", "ｏｒｇ", String(repeating: "a", count: 40)
    ])
    func rejectsLoginThatCouldChangeSearchQuery(_ login: String) {
        #expect(!TargetOrganizations.isValid(login))
    }

    @Test func normalizedTrimsAndDropsInvalidAndDuplicates() {
        let logins = [" shilokuma-inc ", "BeaconFun4", "Shilokuma-Inc", "org:x", ""]
        #expect(TargetOrganizations.normalized(logins) == ["shilokuma-inc", "BeaconFun4"])
    }
}
