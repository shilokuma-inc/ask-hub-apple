@testable import AskHub
import Testing

/// 容量の表示。片付けで何も選んでいないときなどに、英語の「Zero KB」「bytes」を出さない
struct ByteFormatTests {
    @Test
    func zeroIsNumeric() {
        let text = ByteFormat.string(0)
        #expect(text.hasPrefix("0"))
        #expect(!text.localizedCaseInsensitiveContains("zero"))
    }

    @Test
    func smallSizesUseKilobytes() {
        #expect(!ByteFormat.string(512).localizedCaseInsensitiveContains("byte"))
    }
}
