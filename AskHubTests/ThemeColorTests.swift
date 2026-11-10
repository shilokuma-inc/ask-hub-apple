@testable import AskHub
import SwiftUI
import Testing
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// ライトとダークで変わる色は、裏のスレッドで決めても落ちない（SwiftUI は色を `com.apple.SwiftUI.AsyncRenderer` で決めることがある）
@MainActor
struct ThemeColorTests {
    /// 裏のスレッドで、ダークのときの色を決める（MainActor に縛られていると、実行時の確かめで落ちる）
    @Test
    func resolvesDynamicColorOffMainActor() async {
        let accent = Theme.accent
        let red = await Task.detached { () -> Double in
            #if os(iOS)
            let color = UIColor(accent).resolvedColor(with: UITraitCollection(userInterfaceStyle: .dark))
            var red: CGFloat = 0
            color.getRed(&red, green: nil, blue: nil, alpha: nil)
            return Double(red)
            #else
            var red: CGFloat = 0
            NSAppearance(named: .darkAqua)?.performAsCurrentDrawingAppearance {
                NSColor(accent).usingColorSpace(.sRGB)?.getRed(&red, green: nil, blue: nil, alpha: nil)
            }
            return Double(red)
            #endif
        }.value
        // ダークの色（赤 0.74）になる
        #expect(abs(red - 0.74) < 0.02)
    }
}
