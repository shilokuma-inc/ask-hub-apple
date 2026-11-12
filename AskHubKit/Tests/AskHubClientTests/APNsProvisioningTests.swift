import AskHubClient
import AskHubProtocol
import Foundation
import Testing

/// iOS の実機の版の APNs の環境を、埋め込みの provisioning profile から決めること
struct APNsProvisioningTests {
    /// 署名（CMS）で包んだ profile の形。plist の前後に、署名のバイト列が付く
    static func profile(entitlements: [String: Any]) throws -> Data {
        let plist: [String: Any] = ["Name": "iOS Team Provisioning Profile: jp.shilokuma.AskHub", "Entitlements": entitlements]
        let xml = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        return Data([0x30, 0x80, 0x06, 0x09, 0x2a, 0x86, 0x48]) + xml + Data([0xa0, 0x82, 0x0b, 0x00, 0x30, 0x82])
    }

    /// 開発用の署名で作った版は、Release の構成でも profile が development になる（Info.plist のビルド設定は production のまま）
    @Test func readsDevelopmentFromDevelopmentProfile() throws {
        let profile = try Self.profile(entitlements: ["aps-environment": "development", "get-task-allow": true])
        #expect(APNsProvisioning.environment(embeddedProfile: profile) == .development)
    }

    /// Ad Hoc などの配布用の profile は production
    @Test func readsProductionFromDistributionProfile() throws {
        let profile = try Self.profile(entitlements: ["aps-environment": "production"])
        #expect(APNsProvisioning.environment(embeddedProfile: profile) == .production)
    }

    /// App Store・TestFlight の版は profile を外して配られ、APNs は production
    @Test func treatsMissingProfileAsProduction() {
        #expect(APNsProvisioning.environment(embeddedProfile: nil) == .production)
    }

    /// push の entitlement が無い profile・読めない profile からは決めない
    @Test func returnsNilWithoutPushEntitlement() throws {
        #expect(APNsProvisioning.environment(embeddedProfile: try Self.profile(entitlements: ["get-task-allow": true])) == nil)
        #expect(APNsProvisioning.environment(embeddedProfile: try Self.profile(entitlements: ["aps-environment": "staging"])) == nil)
        #expect(APNsProvisioning.environment(embeddedProfile: Data()) == nil)
        #expect(APNsProvisioning.environment(embeddedProfile: Data("<?xml version=\"1.0\"?><plist>".utf8)) == nil)
    }
}
