import Foundation

// 新しいアプリを App Store に載せる準備の人の意図（`docs/renewal/release.md` の「新しいアプリを載せる」）。
// どれも封筒の `repo` が対象のリポジトリで、`target`・`targetVersion` は持たない。
// 司令塔は `app-store.json` に人の意図を写すだけで、App Store Connect への書き込みは見回り（`ReleaseWatch`）が行う

/// 封筒の `repo` を読み、`target`・`targetVersion` を持たないことを確かめる
private func appStoreSetupRepository(_ envelope: IntentEnvelope, kind: String) throws(MalformedIntent) -> RepositoryFullName {
    guard envelope.kind == kind else { throw .init(detail: "kind が \(kind) でない") }
    guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
    guard envelope.target == nil, envelope.targetVersion == nil else { throw .init(detail: "\(kind) に target か targetVersion がある") }
    return repo
}

/// payload を Codable の型で読む。読み飛ばした欄（知らない欄・綴りの誤り）があれば断る
private func decodePayload<Payload: Codable>(_ type: Payload.Type, from envelope: IntentEnvelope) throws(MalformedIntent) -> Payload {
    let value = JSONValue.object(envelope.payload ?? [:])
    let payload: Payload
    do {
        payload = try JSONDecoder().decode(Payload.self, from: CanonicalJSON.data(for: value))
    } catch {
        throw .init(detail: "payload の形が違う（\(error)）")
    }
    guard let encoded = try? JSONValue(parsing: JSONEncoder().encode(payload)), value.isContained(in: encoded) else {
        throw .init(detail: "payload に知らない欄がある")
    }
    return payload
}

private func encodePayload(_ payload: some Encodable) -> [String: JSONValue] {
    guard case let .object(fields)? = (try? JSONEncoder().encode(payload)).flatMap({ try? JSONValue(parsing: $0) }) else { return [:] }
    return fields
}

/// Bundle ID を登録する人の意図（`kind` が `registerBundleId`）。`identifier` はリポジトリのビルドの設定にある Bundle ID のどれか、
/// `platform` はそのプラットフォーム。司令塔が App Store Connect の API（`POST /v1/bundleIds`）で登録する
public struct RegisterBundleIdIntent: Equatable, Sendable {
    public static let kind = "registerBundleId"

    public var repo: RepositoryFullName
    public var identifier: String
    public var platform: BundleIDPlatform
    public var intent: IntentReference

    public init(repo: RepositoryFullName, identifier: String, platform: BundleIDPlatform, intent: IntentReference) {
        self.repo = repo
        self.identifier = identifier
        self.platform = platform
        self.intent = intent
    }

    private struct Payload: Codable {
        var identifier: String
        var platform: BundleIDPlatform
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let repo = try appStoreSetupRepository(envelope, kind: Self.kind)
        let payload = try decodePayload(Payload.self, from: envelope)
        guard AppStoreSetupFile.isBundleID(payload.identifier) else { throw .init(detail: "identifier が Bundle ID の形でない") }
        self.init(
            repo: repo,
            identifier: payload.identifier,
            platform: payload.platform,
            intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        )
    }

    public var payload: [String: JSONValue] { Self.payload(identifier: identifier, platform: platform) }

    /// 送る payload（クライアントが作る）
    public static func payload(identifier: String, platform: BundleIDPlatform) -> [String: JSONValue] {
        encodePayload(Payload(identifier: identifier, platform: platform))
    }
}

/// 決まった値を App Store Connect に書く人の意図（`kind` が `applyAppStoreSettings`）。payload は `AppStoreSettings` の形で、書く欄だけを持つ
/// （価格は無料・配信の地域はすべて・カテゴリ・コンテンツの権利・プライバシーポリシーの URL、初めての版のサポート URL・マーケティング URL・著作権表示・
/// App Review の連絡先をほかのアプリから写す）。人がチェックリストで値を確かめて押す
public struct ApplyAppStoreSettingsIntent: Equatable, Sendable {
    public static let kind = "applyAppStoreSettings"

    public var repo: RepositoryFullName
    public var settings: AppStoreSettings
    public var intent: IntentReference

    public init(repo: RepositoryFullName, settings: AppStoreSettings, intent: IntentReference) {
        self.repo = repo
        self.settings = settings
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let repo = try appStoreSetupRepository(envelope, kind: Self.kind)
        let settings = try decodePayload(AppStoreSettings.self, from: envelope)
        let problems = settings.problems
        guard problems.isEmpty else { throw .init(detail: problems.joined(separator: "、")) }
        self.init(repo: repo, settings: settings, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { Self.payload(settings) }

    /// 送る payload（クライアントが作る）
    public static func payload(_ settings: AppStoreSettings) -> [String: JSONValue] { encodePayload(settings) }
}

/// App Store Connect の Web でした作業を「終わった」にする人の意図（`kind` が `confirmAppStoreItem`）。`item` はチェックリストの項目。
/// API で確かめられない項目（App のプライバシー・DSA の申告）と、確かめが合わないときの上書きに使う。アプリの作成（`app`）は API で確かめるので送れない
public struct ConfirmAppStoreItemIntent: Equatable, Sendable {
    public static let kind = "confirmAppStoreItem"

    public var repo: RepositoryFullName
    public var item: AppStoreSetupFile.ItemKind
    public var intent: IntentReference

    public init(repo: RepositoryFullName, item: AppStoreSetupFile.ItemKind, intent: IntentReference) {
        self.repo = repo
        self.item = item
        self.intent = intent
    }

    private struct Payload: Codable {
        var item: AppStoreSetupFile.ItemKind
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let repo = try appStoreSetupRepository(envelope, kind: Self.kind)
        let payload = try decodePayload(Payload.self, from: envelope)
        guard payload.item != .app else { throw .init(detail: "アプリの作成は API で確かめる（終わったにできない）") }
        self.init(repo: repo, item: payload.item, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { Self.payload(item: item) }

    public static func payload(item: AppStoreSetupFile.ItemKind) -> [String: JSONValue] { encodePayload(Payload(item: item)) }
}

/// App Store に出さない（`excluded` が true）・出すに戻す（false）人の意図（`kind` が `excludeFromAppStore`）。
/// 出さないリポジトリには、司令塔がチェックリストを「あなたの番」に出さない
public struct ExcludeFromAppStoreIntent: Equatable, Sendable {
    public static let kind = "excludeFromAppStore"

    public var repo: RepositoryFullName
    public var excluded: Bool
    public var intent: IntentReference

    public init(repo: RepositoryFullName, excluded: Bool, intent: IntentReference) {
        self.repo = repo
        self.excluded = excluded
        self.intent = intent
    }

    private struct Payload: Codable {
        var excluded: Bool
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        let repo = try appStoreSetupRepository(envelope, kind: Self.kind)
        let payload = try decodePayload(Payload.self, from: envelope)
        self.init(repo: repo, excluded: payload.excluded, intent: IntentReference(keyId: envelope.keyId, nonce: envelope.nonce))
    }

    public var payload: [String: JSONValue] { Self.payload(excluded: excluded) }

    public static func payload(excluded: Bool) -> [String: JSONValue] { encodePayload(Payload(excluded: excluded)) }
}
