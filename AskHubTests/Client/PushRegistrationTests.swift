@testable import AskHub
import Testing

/// 通知の許可と宛先の登録が動く条件
@MainActor
struct PushRegistrationTests {
    /// デモのデータと、アプリの中で動く単体テストでは、通知の許可を求めず宛先も書かない
    @Test
    func runsOnlyForStateRepository() {
        #expect(PushRegistration.isEnabled(source: .stateRepository, environment: [:]))
        #expect(!PushRegistration.isEnabled(source: .demo, environment: [:]))
        let testHost = ["XCTestConfigurationFilePath": "/tmp/x.xctestconfiguration"]
        #expect(!PushRegistration.isEnabled(source: .stateRepository, environment: testHost))
    }
}
