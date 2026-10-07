import AskHubKit
import Foundation
import Observation

/// 一覧を取得する organization の保存先。秘密ではないので UserDefaults に保存する
enum OrganizationSettings {
    static let defaultsKey = "AskHubOrganizations"

    /// 保存した organization。保存していない（または使えるものが無い）ときは既定の organization
    static func load(from defaults: UserDefaults = .standard) -> [String] {
        let saved = TargetOrganizations.normalized(defaults.stringArray(forKey: defaultsKey) ?? [])
        return saved.isEmpty ? TargetOrganizations.defaultLogins : saved
    }

    static func save(_ logins: [String], to defaults: UserDefaults = .standard) {
        defaults.set(TargetOrganizations.normalized(logins), forKey: defaultsKey)
    }
}

/// 設定画面で、一覧を取得する organization を追加・削除するための状態
@MainActor
@Observable
final class OrganizationSettingsModel {
    /// 入力中の organization
    var input = ""
    /// 取得する organization（並べた順に取得する）
    private(set) var logins: [String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        logins = OrganizationSettings.load(from: defaults)
    }

    /// 追加できる入力か（login として使える形で、まだ並んでいない）
    var canAdd: Bool {
        TargetOrganizations.isValid(trimmedInput) && !logins.contains { $0.caseInsensitiveCompare(trimmedInput) == .orderedSame }
    }

    /// 削除できるか。何も取得しなくならないよう、最後の 1 つは残す
    var canRemove: Bool {
        logins.count > 1
    }

    /// 入力した organization を末尾に足して保存し、入力欄を空にする
    func add() {
        guard canAdd else {
            return
        }
        logins.append(trimmedInput)
        OrganizationSettings.save(logins, to: defaults)
        input = ""
    }

    func remove(_ login: String) {
        guard canRemove else {
            return
        }
        logins.removeAll { $0 == login }
        OrganizationSettings.save(logins, to: defaults)
    }

    private var trimmedInput: String {
        input.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
