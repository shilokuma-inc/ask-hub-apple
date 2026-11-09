import AskHubCommander
import Foundation

extension AskHubCommanderMain {
    /// 設定を書き、トークンを Keychain に置き、最初の鍵を固定する
    static func setup(_ arguments: [String]) {
        commandLine.setup(arguments, usage: usage) { configuration in
            // 後から足した APNs の設定は、setup を流し直しても残す
            configuration.apns = APNsSetup.preserved(at: paths.configuration)
        }
        print("次に launch-agent で常駐の定義を書き、出てくるコマンドで登録してください")
    }

    /// APNs の鍵（.p8）を Keychain に置き、鍵の id と Team ID を設定に足す。鍵の値は設定にも出力にも書かない
    static func apns(_ arguments: [String]) {
        let setup: APNsSetup
        do {
            setup = try APNsSetup.parse(arguments)
        } catch {
            fail("\(error.message)\n\(usage)", status: EX_USAGE)
        }
        guard var configuration = try? MachineConfiguration.load(from: paths.configuration, role: .commander) else {
            fail("設定（\(paths.configuration.path)）を読めない。先に setup を流す", status: EX_CONFIG)
        }
        let url = URL(fileURLWithPath: (setup.keyFile as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url), APNsKey.parse(data) != nil else {
            fail("\(url.path) を APNs の鍵（.p8）として読めない", status: EX_DATAERR)
        }
        configuration.apns = setup.configuration
        do {
            try commandLine.secrets.write(data, for: .apnsKey)
            try configuration.save(to: paths.configuration)
        } catch {
            fail("APNs の鍵を登録できない（\(error)）", status: EX_SOFTWARE)
        }
        print("""
            APNs の鍵（\(setup.configuration.keyId)、Team \(setup.configuration.teamId)、\(setup.configuration.topic)）を Keychain に置き、設定に足しました。
            \(url.path) はこの Mac に残さず、安全な場所（パスワードマネージャーなど）に移してください（Apple Developer からは一度しか落とせません）。
            常駐を読み込み直すと、通知を送り始めます:
              launchctl kickstart -k gui/\(getuid())/\(MachineRole.commander.launchAgentLabel)
            """)
    }

    /// 設定と Keychain の様子を出す（秘密の値は出さない）
    static func check() async {
        let configuration = try? MachineConfiguration.load(from: paths.configuration, role: .commander)
        let key = APNsKey.state(in: commandLine.secrets).rawValue
        let apns = configuration?.apns.map { "\($0.keyId)（Team \($0.teamId)、\($0.topic)）、鍵: \(key)" }
        let lines = await commandLine.checkLines(version: CommanderVersion.current) + ["APNs: \(apns ?? "設定していない（通知を送らない。apns で登録する）")"]
        print(lines.joined(separator: "\n"))
    }
}
