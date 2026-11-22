import Foundation

/// 新しいアプリのリポジトリを作るテンプレート（`docs/renewal/operations.md` の「テンプレートからの新規作成」）。
/// 元にするリポジトリは決まったものだけにし、人の意図には種類だけを書く（任意のリポジトリから作らせない）
public enum RepositoryTemplate: String, Codable, Sendable, CaseIterable {
    case ios
    case visionos

    /// 元にするテンプレートのリポジトリ
    public var repository: RepositoryFullName {
        switch self {
        case .ios: RepositoryFullName(rawValue: "shilokuma-inc/template-app-ios")!
        case .visionos: RepositoryFullName(rawValue: "shilokuma-vision/template-app-visionos")!
        }
    }

    /// 画面に出す名前
    public var title: String {
        switch self {
        case .ios: "iOS"
        case .visionos: "visionOS"
        }
    }

    /// 作った後に入れるビルドの設定（テンプレートの Build のワークフローのチェック `build / build` を待ち、
    /// 子 PR は単体テストだけ・最終 PR は UI テストまで流す）。アプリ名がプロジェクト名の決まりに合わなければ投げる
    public func build(appName: String) throws(BuildSettingsError) -> RepositoryFile.Build {
        let destination: SimulatorDestination = switch self {
        case .ios: SimulatorDestination(platform: .iOS, deviceType: "iPhone 17 Pro")
        case .visionos: SimulatorDestination(platform: .visionOS, deviceType: "Apple Vision Pro")
        }
        let xcode = try BuildSettings(
            project: "\(appName).xcodeproj",
            scheme: appName,
            destinations: [.simulator(destination)],
            testLight: TestSelection(onlyTesting: ["\(appName)Tests"]),
            testFull: TestSelection()
        )
        return RepositoryFile.Build(
            xcode: xcode,
            childChecks: ProtectionPolicy.defaultRequiredChecks,
            finalChecks: ProtectionPolicy.defaultRequiredChecks,
            trustedReviewers: ["coderabbitai[bot]"]
        )
    }
}

/// 作るリポジトリの公開範囲
public enum RepositoryVisibility: String, Codable, Sendable, CaseIterable {
    case `public`
    case `private`
}

/// テンプレートから新しいアプリのリポジトリを作る人の意図（`createRepository`）。封筒の `repo` が作るリポジトリ（持ち主と名前）。
/// `target`・`targetVersion` は持たない。司令塔が管理用のトークンで作り、名前を書き換え、対象に加える
public struct CreateRepositoryIntent: Equatable, Sendable {
    public static let kind = "createRepository"
    /// アプリ名の長さの上限（Swift のモジュール名・Xcode のプロジェクト名になる）
    public static let maximumAppNameLength = 60
    /// Bundle ID の長さの上限（App Store Connect の上限）
    public static let maximumBundleIdLength = 155

    public var repo: RepositoryFullName
    public var template: RepositoryTemplate
    public var visibility: RepositoryVisibility
    /// アプリ名（英字で始まる英数字。テンプレートの `scripts/rename.sh` に渡す名前と同じ決まり）
    public var appName: String
    public var bundleId: String
    public var intent: IntentReference

    public init(
        repo: RepositoryFullName,
        template: RepositoryTemplate,
        visibility: RepositoryVisibility,
        appName: String,
        bundleId: String,
        intent: IntentReference
    ) {
        self.repo = repo
        self.template = template
        self.visibility = visibility
        self.appName = appName
        self.bundleId = bundleId
        self.intent = intent
    }

    public init(envelope: IntentEnvelope) throws(MalformedIntent) {
        guard envelope.kind == Self.kind else { throw .init(detail: "kind が createRepository でない") }
        guard let repo = envelope.repo else { throw .init(detail: "repo が無い") }
        guard envelope.target == nil, envelope.targetVersion == nil else { throw .init(detail: "作る意図に target か targetVersion がある") }
        let reader = try PayloadReader(envelope.payload, allowed: ["template", "visibility", "appName", "bundleId"])
        guard let template = RepositoryTemplate(rawValue: try reader.text("template", required: true, limit: 32)) else {
            throw .init(detail: "template が知らない値")
        }
        guard let visibility = RepositoryVisibility(rawValue: try reader.text("visibility", required: true, limit: 16)) else {
            throw .init(detail: "visibility が知らない値")
        }
        let appName = try reader.text("appName", required: true, limit: Self.maximumAppNameLength)
        guard Self.isAppName(appName) else { throw .init(detail: "appName は英字で始まる英数字") }
        let bundleId = try reader.text("bundleId", required: true, limit: Self.maximumBundleIdLength)
        guard Self.isBundleId(bundleId) else { throw .init(detail: "bundleId の形が違う") }
        let intent = IntentReference(keyId: envelope.keyId, nonce: envelope.nonce)
        self.init(repo: repo, template: template, visibility: visibility, appName: appName, bundleId: bundleId, intent: intent)
    }

    public var payload: [String: JSONValue] {
        [
            "template": .string(template.rawValue),
            "visibility": .string(visibility.rawValue),
            "appName": .string(appName),
            "bundleId": .string(bundleId)
        ]
    }

    /// 英字で始まる英数字（ASCII だけ）
    public static func isAppName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, (1...maximumAppNameLength).contains(name.unicodeScalars.count) else { return false }
        return isLetter(first) && name.unicodeScalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) }
    }

    /// 英数字とハイフンの部分を `.` でつないだもの（部分は 2 つ以上）
    public static func isBundleId(_ id: String) -> Bool {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        return id.unicodeScalars.count <= maximumBundleIdLength && parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { isLetter($0) || ("0"..."9").contains($0) || $0 == "-" }
        }
    }

    /// アプリ名から決まる既定の Bundle ID（テンプレートの既定と同じ形）
    public static func defaultBundleId(appName: String) -> String {
        "jp.shilokuma.\(appName)"
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }
}

extension RepositoryFile {
    /// テンプレートから作った記録（`createRepository` を処理した司令塔が書く）。対象に加えただけのリポジトリには無い
    public struct Creation: Codable, Equatable, Sendable {
        public var template: RepositoryTemplate
        public var appName: String
        public var bundleId: String
        public var visibility: RepositoryVisibility
        /// アプリ名・Bundle ID を書き換えたコミット。まだ書き換えていなければ nil
        public var renameCommit: String?
        public var intent: IntentReference
        public var at: Timestamp

        public init(
            template: RepositoryTemplate,
            appName: String,
            bundleId: String,
            visibility: RepositoryVisibility,
            renameCommit: String? = nil,
            intent: IntentReference,
            at: Timestamp
        ) {
            self.template = template
            self.appName = appName
            self.bundleId = bundleId
            self.visibility = visibility
            self.renameCommit = renameCommit
            self.intent = intent
            self.at = at
        }

        var problems: [String] {
            var problems: [String] = []
            if !CreateRepositoryIntent.isAppName(appName) { problems.append("created.appName は英字で始まる英数字") }
            if !CreateRepositoryIntent.isBundleId(bundleId) { problems.append("created.bundleId の形が違う") }
            if let renameCommit, !AttemptFile.isCommitSHA(renameCommit) { problems.append("created.renameCommit の形が違う") }
            return problems
        }
    }
}
