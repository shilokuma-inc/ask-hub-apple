@testable import AskHubCommander
import AskHubProtocol
import Foundation
import Testing

/// 実行ファイルに埋め込んだ Info.plist から読む版とコミット（`scripts/machine/build.sh`）
struct CommanderVersionTests {
    static let commit = "0123456789abcdef0123456789abcdef01234567"

    @Test func readsEmbeddedVersionAndCommit() {
        let build = CommanderVersion.Build(infoDictionary: [
            "CFBundleIdentifier": "jp.shilokuma.askhub.worker",
            "CFBundleShortVersionString": "0.2.0-3-gabc1234",
            "AskHubCommit": Self.commit
        ])
        #expect(build.version == "0.2.0-3-gabc1234")
        #expect(build.commit == Self.commit)
        #expect(build.summary == "0.2.0-3-gabc1234、コミット \(Self.commit)、互換の番号 \(MachineCompatibility.current)")
    }

    /// 埋め込んでいない・ほかのプログラムの Info.plist（テストを流す xctest など）・版の無いものは、埋め込んでいないビルドとみなす
    @Test func treatsMissingOrForeignInfoAsDevelopment() {
        let infos: [[String: Any]?] = [
            nil,
            [:],
            ["CFBundleIdentifier": "com.apple.dt.xctest.tool", "CFBundleShortVersionString": "26.6"],
            ["CFBundleIdentifier": "jp.shilokuma.askhub.commander", "CFBundleShortVersionString": ""],
            ["CFBundleShortVersionString": "0.2.0"]
        ]
        for info in infos {
            let build = CommanderVersion.Build(infoDictionary: info)
            #expect(build.version == "0.0.0-dev")
            #expect(build.commit == nil)
        }
        #expect(CommanderVersion.Build(infoDictionary: nil).summary == "0.0.0-dev、コミット 埋め込んでいない、互換の番号 \(MachineCompatibility.current)")
        // テストは埋め込んでいないビルドで流れる
        #expect(CommanderVersion.current == "0.0.0-dev")
    }

    /// タグそのものの版はコミットを含まないので、コミットは別の欄から読む。空のコミットは無いとみなす
    @Test func readsCommitSeparatelyFromTaggedVersion() {
        let tagged = CommanderVersion.Build(infoDictionary: [
            "CFBundleIdentifier": "jp.shilokuma.askhub.cli",
            "CFBundleShortVersionString": "0.2.0",
            "AskHubCommit": Self.commit
        ])
        #expect(tagged.version == "0.2.0")
        #expect(tagged.commit == Self.commit)
        let empty = CommanderVersion.Build(infoDictionary: [
            "CFBundleIdentifier": "jp.shilokuma.askhub.commander",
            "CFBundleShortVersionString": "0.2.0",
            "AskHubCommit": ""
        ])
        #expect(empty.commit == nil)
    }
}
