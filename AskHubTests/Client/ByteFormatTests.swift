@testable import AskHub
import Testing

/// 容量の表示。片付けで何も選んでいないときなどに、英語の「Zero KB」「bytes」を出さない
struct ByteFormatTests {
    /// 0 は「Zero KB」ではなく、数字で出す
    @Test
    func zeroIsNumeric() {
        let text = ByteFormat.string(0)
        #expect(text.hasPrefix("0"))
        #expect(!text.localizedCaseInsensitiveContains("zero"))
    }

    /// 1 KB に満たない大きさも「bytes」ではなく KB で出す
    @Test
    func smallSizesUseKilobytes() {
        #expect(!ByteFormat.string(512).localizedCaseInsensitiveContains("byte"))
    }
}
