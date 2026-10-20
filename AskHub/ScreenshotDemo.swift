//
//  ScreenshotDemo.swift
//  AskHub
//
//  App Store 用スクリーンショットの撮影モード（template-app-ios の ScreenshotDemo と同じ形）。
//  撮影のスクリプトが次の起動引数でアプリを起動し、目的の画面をデモモードのサンプルデータで開かせる。
//
//    -screenshot-demo -screenshot-scene <Scene の rawValue> -AppleLanguages (<言語>) -AppleLocale <ロケール>
//
//  画面を足すときは、Scene に case を足し、下の `tab` で開くタブを返し、
//  AppStore/screenshots.json の scenes に同じ rawValue を足す（突き合わせは Tools/app_store_config.py が行う。
//  正規表現で `enum Scene: String {` から最初の `}` までの `case` を読むので、Scene の中に case 以外の宣言を書かない）。
//  サンプルデータは既存のデモモードのもの（SampleInbox など）を使う。UserDefaults のデモモードの設定は書き換えない。
//  撮影は Release でビルドするので、#if DEBUG にしない
//

import Foundation

enum ScreenshotDemo {
    /// 撮る画面。rawValue が AppStore/screenshots.json の scene と対応する（App Store は 1 表示サイズにつき 10 枚まで）
    enum Scene: String {
        case action
        case request
        case decisions
        case status
        case verification
    }

    /// 撮影モードで起動する起動引数
    static let enabledArgument = "-screenshot-demo"
    /// 撮る画面を渡す起動引数。続く引数が Scene の rawValue
    static let sceneArgument = "-screenshot-scene"

    /// 撮影モードで起動しているか
    static let isEnabled = isEnabled(in: ProcessInfo.processInfo.arguments)

    /// 撮影モードで開く画面。撮影モードでないときと、知らない値を渡されたときは nil
    static let scene: Scene? = scene(in: ProcessInfo.processInfo.arguments)

    /// 起動引数に撮影モードの指定があるか
    static func isEnabled(in arguments: [String]) -> Bool {
        arguments.contains(enabledArgument)
    }

    /// 起動引数から撮る画面を読む。撮影モードでないとき・値が無いとき・知らない値のときは nil
    static func scene(in arguments: [String]) -> Scene? {
        guard isEnabled(in: arguments) else {
            return nil
        }
        guard let index = arguments.firstIndex(of: sceneArgument), arguments.indices.contains(index + 1) else {
            return nil
        }
        return Scene(rawValue: arguments[index + 1])
    }
}

// `enum Scene: String {` の形を崩さないよう、準拠は extension で足す
extension ScreenshotDemo.Scene: CaseIterable {
    /// この画面を撮るときに開くタブ
    var tab: AppTab {
        switch self {
        case .action:
            .action

        case .request:
            .request

        case .decisions:
            .decisions

        case .status:
            .status

        case .verification:
            .verification
        }
    }
}
