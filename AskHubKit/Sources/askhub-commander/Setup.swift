import AskHubCommander
import Foundation

extension AskHubCommanderMain {
    /// 設定を書き、トークンを Keychain に置き、最初の鍵を固定する
    static func setup(_ arguments: [String]) {
        commandLine.setup(arguments, usage: usage) { configuration in
            // 後から足した APNs の設定は、setup を流し直しても残す
            configuration.apns = APNsSetup.preserved(at: paths.configuration)
            configuration.appStoreConnect = AppStoreConnectSetup.preserved(at: paths.configuration)
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

    /// App Store Connect の API キー（.p8）を Keychain に置き、鍵の id と Issuer ID を設定に足す。鍵の値は設定にも出力にも書かない
    static func appStoreConnect(_ arguments: [String]) {
        let setup: AppStoreConnectSetup
        do {
            setup = try AppStoreConnectSetup.parse(arguments)
        } catch {
            fail("\(error.message)\n\(usage)", status: EX_USAGE)
        }
        guard var configuration = try? MachineConfiguration.load(from: paths.configuration, role: .commander) else {
            fail("設定（\(paths.configuration.path)）を読めない。先に setup を流す", status: EX_CONFIG)
        }
        let url = URL(fileURLWithPath: (setup.keyFile as NSString).expandingTildeInPath)
        guard let data = try? Data(contentsOf: url), AppStoreConnectKey.parse(data) != nil else {
            fail("\(url.path) を App Store Connect の API キー（.p8）として読めない", status: EX_DATAERR)
        }
        configuration.appStoreConnect = AppStoreConnectSetup.adding(setup.configuration, to: configuration.appStoreConnect)
        do {
            try commandLine.secrets.write(data, for: .appStoreConnectKey(id: setup.configuration.keyId))
            try configuration.save(to: paths.configuration)
        } catch {
            fail("App Store Connect の API キーを登録できない（\(error)）", status: EX_SOFTWARE)
        }
        print("""
            App Store Connect の API キー（\(setup.configuration.keyId)、Issuer \(setup.configuration.issuerId)）を Keychain に置き、設定に足しました。
            \(url.path) はこの Mac に残さず、安全な場所（パスワードマネージャーなど）に移してください（App Store Connect からは一度しか落とせません）。
            常駐を読み込み直すと、30 分ごとに App Store での配信を見回り始めます:
              launchctl kickstart -k gui/\(getuid())/\(MachineRole.commander.launchAgentLabel)
            """)
    }

    /// 版と互換の番号・設定と Keychain の様子を出す（秘密の値は出さない）。
    /// `versionOnly` なら版・コミット・互換の番号だけを出す（Keychain を読まないので、ssh のセッションからも流せる）
    static func check(versionOnly: Bool = false) async {
        guard !versionOnly else {
            return print(CommanderVersion.build.summary)
        }
        let configuration = try? MachineConfiguration.load(from: paths.configuration, role: .commander)
        let key = APNsKey.state(in: commandLine.secrets).rawValue
        let apns = configuration?.apns.map { "\($0.keyId)（Team \($0.teamId)、\($0.topic)）、鍵: \(key)" }
        let stores = (configuration?.appStoreConnect ?? []).map { store in
            "\(store.keyId)（Issuer \(store.issuerId)）、鍵: \(AppStoreConnectKey.state(of: store, in: commandLine.secrets).rawValue)"
        }
        let appStore = stores.isEmpty ? "設定していない（配信を見つけない。app-store-connect で登録する）" : stores.joined(separator: "・")
        let lines = await commandLine.checkLines(version: CommanderVersion.build.summary)
            + ["APNs: \(apns ?? "設定していない（通知を送らない。apns で登録する）")", "App Store Connect: \(appStore)"]
        print(lines.joined(separator: "\n"))
    }
}
