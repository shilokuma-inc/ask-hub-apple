//
//  MacScreenshotCaptureTests.swift
//  AskHubTests
//
//  App Store の Mac のスクリーンショット（APP_DESKTOP）を撮る（Discussion #605 の Q8）。
//  Tools/capture_mac_screenshots.sh が、撮る画面・言語・寸法・出力先を書いた JSON のパスを
//  環境変数 ASKHUB_SCREENSHOT_PLAN（xcodebuild には TEST_RUNNER_ASKHUB_SCREENSHOT_PLAN で渡す）に入れて
//  このテストだけを流す。環境変数が無いとき（build.yml の Unit テストなど）は何もせずに飛ばす。
//
//  GitHub のホストランナーには画面収録の許可が無く、macOS の UI テストや screencapture では撮れないことがあるので、
//  撮影モードと同じ画面（ContentView をサンプルデータで、Scene のタブを開いた状態）を NSHostingView に載せた
//  ウィンドウに置き、cacheDisplay でウィンドウのタイトルバーごと PNG にする（画面収録の許可は要らない）。
//

#if os(macOS)
import AppKit
@testable import AskHub
import Foundation
import SwiftUI
import Testing

/// capture_mac_screenshots.sh が書く撮影の指定。
/// `.enabled(if:)` の条件は MainActor の外で評価されるので、MainActor 既定から外す
nonisolated private struct MacScreenshotPlan: Decodable {
    struct Language: Decodable {
        /// 出力先のフォルダ名（languages.json の language）
        let language: String
        /// 画面に渡すロケール（languages.json の appleLocale）
        let appleLocale: String
    }

    struct Shot: Decodable {
        /// 出力するファイル名（拡張子なし）
        let file: String
        /// ScreenshotDemo.Scene の rawValue
        let scene: String
    }

    /// 出力する画像の幅と高さ（ピクセル）。ウィンドウはこの半分のポイントで作り、2 倍で描く
    let width: Int
    let height: Int
    /// `<outputDirectory>/<language>/<file>.png` に書く
    let outputDirectory: String
    let languages: [Language]
    let scenes: [Shot]

    static let environmentKey = "ASKHUB_SCREENSHOT_PLAN"

    static var path: String? {
        ProcessInfo.processInfo.environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 }
    }
}

@MainActor
@Suite(.enabled(if: MacScreenshotPlan.path != nil, "撮影のときだけ流す（ASKHUB_SCREENSHOT_PLAN が無い）"))
struct MacScreenshotCaptureTests {
    /// 描く倍率。Retina と同じく 2 倍で描き、2880x1800 なら 1440x900 ポイントのウィンドウにする
    private static let scale = 2

    /// SwiftUI の初回の描画とサンプルデータの読み込み（ContentView の task）が終わるまで待つ時間
    private static let settleDuration = Duration.seconds(3)

    @Test("撮影の指定どおりに、言語 × 画面ぶんの PNG を書く")
    func captureScreenshots() async throws {
        let path = try #require(MacScreenshotPlan.path)
        let plan = try JSONDecoder().decode(MacScreenshotPlan.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        try #require(plan.width.isMultiple(of: Self.scale) && plan.height.isMultiple(of: Self.scale), "寸法は \(Self.scale) の倍数にする")
        try #require(!plan.languages.isEmpty && !plan.scenes.isEmpty)

        for language in plan.languages {
            let directory = URL(fileURLWithPath: plan.outputDirectory).appending(path: language.language)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for shot in plan.scenes {
                let scene = try #require(ScreenshotDemo.Scene(rawValue: shot.scene), "ScreenshotDemo.Scene に無い scene: \(shot.scene)")
                let png = try await capture(scene: scene, locale: Locale(identifier: language.appleLocale), plan: plan)
                try png.write(to: directory.appending(path: "\(shot.file).png"))
            }
        }
    }

    /// 撮影モードと同じ画面をウィンドウに出し、タイトルバーごと PNG にする
    private func capture(scene: ScreenshotDemo.Scene, locale: Locale, plan: MacScreenshotPlan) async throws -> Data {
        let size = CGSize(width: plan.width / Self.scale, height: plan.height / Self.scale)
        // モデルは撮るたびに作り直し、前の画面の状態（選んだ行・スクロール位置）を持ち越さない
        let content = ContentView(
            model: .sample(),
            requestModel: .sample(),
            mergeModel: .sample(),
            loopModel: .sample(),
            initialTab: scene.tab
        )
        .environment(\.locale, locale)

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // 手元の Mac ではマウスの位置にある行が選ばれて詳細が開いた写真になったので、マウスの操作を受けない
        window.ignoresMouseEvents = true
        window.appearance = NSAppearance(named: .aqua)
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .aqua)
        window.contentView = hostingView
        // タイトルバー（タブとツールバー）を含めたウィンドウの枠全体を寸法に合わせる（撮るのは枠全体）
        window.setFrame(CGRect(origin: CGPoint(x: 80, y: 80), size: size), display: true)
        window.orderFrontRegardless()
        defer { window.close() }

        try await Task.sleep(for: Self.settleDuration)
        // 一度描いた後にサンプルデータが入ると、List の行の高さが計算し直されず、行が重なって写る（要対応のタブで発生）。
        // ウィンドウの大きさを一度変えて戻すと計算し直されるので、そうしてからもう一度待つ
        let frame = window.frame
        window.setFrame(frame.insetBy(dx: 0, dy: -1), display: true)
        window.setFrame(frame, display: true)
        try await Task.sleep(for: Self.settleDuration)

        // contentView の親（タイトルバーとツールバーを含むウィンドウの枠の View）を描く
        let frameView = try #require(hostingView.superview)
        frameView.layoutSubtreeIfNeeded()
        let bounds = frameView.bounds
        try #require(bounds.size == size, "ウィンドウの大きさが寸法と合いません: \(bounds.size)")
        let representation = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: plan.width,
                pixelsHigh: plan.height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        // ポイントの大きさを寸法の半分にして、2 倍の解像度で描かせる
        representation.size = bounds.size
        frameView.cacheDisplay(in: bounds, to: representation)
        return try #require(representation.representation(using: .png, properties: [:]))
    }
}
#endif
