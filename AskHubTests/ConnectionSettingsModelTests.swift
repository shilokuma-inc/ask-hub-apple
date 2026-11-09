@testable import AskHub
import AskHubKeychain
import Foundation
import Testing

/// 設定の「この端末の鍵」の、登録のコマンドに入れる端末の名前
@MainActor
struct ConnectionSettingsModelTests {
    /// 空白や括弧のある名前も、引用符で囲んで 1 つの引数として渡す
    @Test func commandQuotesLabel() {
        let command = ConnectionSettingsModel.registerCommand(publicKey: "MFkw", account: "octocat", label: "MacBook Pro (M1 Pro)")
        #expect(command == "askhub key add --public-key MFkw --account octocat --label 'MacBook Pro (M1 Pro)'")
    }

    /// 単一引用符は、引用を閉じてエスケープしてから開き直す
    @Test func quotesSingleQuote() {
        #expect(ConnectionSettingsModel.shellQuoted("Taro's Mac") == #"'Taro'\''s Mac'"#)
        #expect(ConnectionSettingsModel.shellQuoted("$(id) `id` \"x\"") == #"'$(id) `id` "x"'"#)
    }

    /// 前後の空白を除き、続く空白・改行は 1 つの空白にまとめる
    @Test func collapsesWhitespace() {
        #expect(ConnectionSettingsModel.deviceLabel(from: "  MacBook\n Pro\t(M1 Pro)  ") == "MacBook Pro (M1 Pro)")
    }

    /// 公開鍵の記録が受け付ける 64 文字（書記素の数）に切り詰める
    @Test func truncatesToLedgerLimit() {
        let label = ConnectionSettingsModel.deviceLabel(from: String(repeating: "🍎", count: 70))
        #expect(label.count == 64)
        // 切った端の空白は残さない
        let spaced = ConnectionSettingsModel.deviceLabel(from: String(repeating: "a", count: 63) + " b")
        #expect(spaced == String(repeating: "a", count: 63))
    }

    /// 名前が空なら既定の名前を使う
    @Test(arguments: ["", "   ", "\n"])
    func blankNameFallsBackToDefault(_ name: String) {
        #expect(ConnectionSettingsModel.deviceLabel(from: name) == ConnectionSettingsModel.defaultDeviceLabel)
        #expect(!ConnectionSettingsModel.defaultDeviceLabel.isEmpty)
        #expect(ConnectionSettingsModel.defaultDeviceLabel.count <= ConnectionSettingsModel.maxDeviceLabelLength)
    }

    /// 入れた名前は端末に残り、次に開いたときも使う。入れていなければ既定の名前
    @Test func remembersDeviceName() throws {
        let defaults = try #require(UserDefaults(suiteName: "ConnectionSettingsModelTests.\(UUID().uuidString)"))
        let model = ConnectionSettingsModel(tokens: InMemorySecretStore(), defaults: defaults)
        #expect(model.deviceName == ConnectionSettingsModel.defaultDeviceLabel)
        #expect(defaults.string(forKey: ConnectionSettingsModel.deviceNamePreferenceKey) == nil)

        model.deviceName = "MacBook Pro (M1 Pro)"
        let reopened = ConnectionSettingsModel(tokens: InMemorySecretStore(), defaults: defaults)
        #expect(reopened.deviceName == "MacBook Pro (M1 Pro)")
    }

    #if os(macOS)
    /// 引用したラベルをシェルに渡すと、元の名前の 1 つの引数になる
    @Test(arguments: ["MacBook Pro (M1 Pro)", "Taro's Mac", "a'b''c", "$(touch x) `id` ; | & < > * ? ! \\ \"", "太郎の Mac mini"])
    func shellReadsQuotedLabelAsOneArgument(_ label: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf '%s|' \(ConnectionSettingsModel.shellQuoted(label))"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        let printed = String(bytes: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        process.waitUntilExit()
        #expect(printed == label + "|")
    }
    #endif
}
