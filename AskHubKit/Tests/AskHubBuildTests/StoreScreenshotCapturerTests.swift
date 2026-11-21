@testable import AskHubBuild
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// テスト用の PNG（`size` の白地に、`mark` の所だけ赤く塗る）
func storeScreenshotPNG(width: Int = 60, height: Int = 120, mark: CGRect? = nil) -> Data {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = CGImageAlphaInfo.premultipliedLast.rawValue
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: alpha)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    if let mark {
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        // CoreGraphics は左下が原点。上からの位置で塗る
        context.fill(CGRect(x: mark.minX, y: CGFloat(height) - mark.maxY, width: mark.width, height: mark.height))
    }
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

/// App Store のスクショの撮影（UI テストの添付の取り出し）と、比べ方
struct StoreScreenshotCapturerTests {
    @Test func readsImageAttachmentsInOrder() throws {
        let manifest = """
            [{"testIdentifier":"AppStoreScreenshotTests/testCapture()","attachments":[
              {"exportedFileName":"b.png","suggestedHumanReadableName":"02-予定の詳細_0_6E1B2C3D-0000-1111-2222-333344445555.png",
               "isAssociatedWithFailure":false,"timestamp":20,"configurationName":"c","deviceName":"d","deviceId":"e"},
              {"exportedFileName":"a.png","suggestedHumanReadableName":"01-ホーム_0_6E1B2C3D-0000-1111-2222-333344445556.png",
               "isAssociatedWithFailure":false,"timestamp":10,"configurationName":"c","deviceName":"d","deviceId":"e"},
              {"exportedFileName":"log.txt","suggestedHumanReadableName":"ログ","isAssociatedWithFailure":false,"timestamp":15,
               "configurationName":"c","deviceName":"d","deviceId":"e"},
              {"exportedFileName":"fail.png","suggestedHumanReadableName":"失敗","isAssociatedWithFailure":true,"timestamp":30,
               "configurationName":"c","deviceName":"d","deviceId":"e"}
            ]}]
            """
        let directory = URL(fileURLWithPath: "/tmp/attachments")
        let shots = StoreScreenshotCapturer.images(in: Data(manifest.utf8), directory: directory)
        // 添付した順（時刻の順）に、画像だけ。失敗に結びついた添付は使わない
        #expect(shots == [
            CapturedShot(name: "01-ホーム", file: directory.appendingPathComponent("a.png")),
            CapturedShot(name: "02-予定の詳細", file: directory.appendingPathComponent("b.png"))
        ])
    }

    @Test func passesEnvironmentToTheTestRunner() {
        #expect(StoreScreenshotCapturer.testEnvironment(["APP_STORE_LANGUAGE": "ja", "APP_STORE_SCREENSHOTS": "1"]) == [
            "TEST_RUNNER_APP_STORE_LANGUAGE=ja", "TEST_RUNNER_APP_STORE_SCREENSHOTS=1"
        ])
        #expect(StoreScreenshotCapturer.name("01-ホーム") == "01-ホーム")
    }

    @Test func comparesScreenshotsAndFindsTheChangedArea() throws {
        let plain = storeScreenshotPNG()
        #expect(ScreenshotDiff.compare(before: plain, after: storeScreenshotPNG()) == ScreenshotDifference(changed: false))
        let marked = storeScreenshotPNG(mark: CGRect(x: 30, y: 60, width: 15, height: 30))
        let difference = ScreenshotDiff.compare(before: plain, after: marked)
        #expect(difference.changed)
        let area = try #require(difference.area)
        #expect(abs(area.minX - 0.5) < 0.02 && abs(area.minY - 0.5) < 0.02)
        #expect(abs(area.width - 0.25) < 0.02 && abs(area.height - 0.25) < 0.02)
        // 大きさが違えば、所は分からないが違う
        #expect(ScreenshotDiff.compare(before: plain, after: storeScreenshotPNG(width: 80)) == ScreenshotDifference(changed: true))
        // 見本は幅を縮めた JPEG
        let preview = try #require(ScreenshotDiff.preview(of: marked, width: 30))
        let source = try #require(CGImageSourceCreateWithData(preview as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        #expect(CGImageSourceCreateImageAtIndex(source, 0, nil)?.width == 30)
    }
}
