@testable import AskHub
import Foundation
import Testing

/// 開始のときに回す Mac を選ぶシート
@MainActor
struct StartSheetTests {
    /// Mac の行を押すと、その Mac に選び直す。断る理由がある Mac は押しても選ばず、前の選択のまま
    @Test
    func tappingMacRowMovesChoiceExceptRefusingMac() throws {
        let snapshot = DemoScenario.standard.snapshot(now: Date(timeIntervalSince1970: 1_800_000_000))
        var mac = try #require(snapshot.mac(DemoData.macMiniID))
        mac.refusalReason = nil
        #expect(StartSheet.choice(after: mac, from: DemoData.macBookProID) == DemoData.macMiniID)
        #expect(StartSheet.choice(after: mac, from: nil) == DemoData.macMiniID)
        mac.refusalReason = "空き容量が 30 GB を下回っています"
        #expect(StartSheet.choice(after: mac, from: DemoData.macBookProID) == DemoData.macBookProID)
        #expect(StartSheet.choice(after: mac, from: nil) == nil)
    }
}
