import Foundation

/// リポジトリのビルドとテストの設定（`docs/renewal/operations.md` の「ビルドの設定の入れ方」）。
/// 状態リポジトリの `repo.json` の `build.xcode` に置く（`RepositoryFile.Build`）。ワーカーはこれだけから決まった形の
/// `xcodebuild` を組み立て（`AskHubBuild`）、Claude に引数を書かせない。
///
/// 読むとき（`init(from:)`）と作るときに形を確かめる。パスはリポジトリの直下からの相対パスに限り、`..` を含むものや、
/// 引数として読まれる `-` 始まりの値は受け付けない
public struct BuildSettings: Codable, Equatable, Sendable {
    /// `.xcodeproj` か `.xcworkspace` の、リポジトリの直下からの相対パス
    public var project: String
    /// ビルドの前にプロジェクトを作る道具。nil ならリポジトリにあるプロジェクトをそのまま使う
    public var generate: ProjectGenerator?
    public var scheme: String
    /// ビルドとテストの行き先。並べた順に流す
    public var destinations: [BuildDestination]
    /// 軽いテスト（`testLight`。子 PR の前に流す。macOS のランナーを節約するもの）
    public var testLight: TestSelection
    /// 全部のテスト（`testFull`。最終 PR を出す前に流す。UI テストを含む）
    public var testFull: TestSelection

    public init(
        project: String,
        generate: ProjectGenerator? = nil,
        scheme: String,
        destinations: [BuildDestination],
        testLight: TestSelection = TestSelection(),
        testFull: TestSelection = TestSelection()
    ) throws(BuildSettingsError) {
        self.project = project
        self.generate = generate
        self.scheme = scheme
        self.destinations = destinations
        self.testLight = testLight
        self.testFull = testFull
        try validate()
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        project = try container.decode(String.self, forKey: .project)
        generate = try container.decodeIfPresent(ProjectGenerator.self, forKey: .generate)
        scheme = try container.decode(String.self, forKey: .scheme)
        destinations = try container.decode([BuildDestination].self, forKey: .destinations)
        testLight = try container.decodeIfPresent(TestSelection.self, forKey: .testLight) ?? TestSelection()
        testFull = try container.decodeIfPresent(TestSelection.self, forKey: .testFull) ?? TestSelection()
        do {
            try validate()
        } catch {
            throw DecodingError.dataCorrupted(DecodingError.Context(codingPath: decoder.codingPath, debugDescription: error.description))
        }
    }

    /// 形を確かめる。`xcodebuild` の引数やファイルのパスに使う値に、別の意味を持たせない
    public func validate() throws(BuildSettingsError) {
        try Self.checkRelativePath(project, field: "project")
        guard project.hasSuffix(".xcodeproj") || project.hasSuffix(".xcworkspace") else {
            throw BuildSettingsError(field: "project", reason: "`.xcodeproj` か `.xcworkspace` を指していない")
        }
        try Self.checkArgument(scheme, field: "scheme")
        guard !destinations.isEmpty else { throw BuildSettingsError(field: "destinations", reason: "行き先が無い") }
        guard Set(destinations).count == destinations.count else {
            throw BuildSettingsError(field: "destinations", reason: "同じ行き先が重なっている")
        }
        for destination in destinations {
            try destination.validate()
        }
        try testLight.validate(field: "testLight")
        try testFull.validate(field: "testFull")
    }

    /// 相対パス。空・絶対パス・`-` 始まり・`..` や空の要素・制御文字を許さない
    static func checkRelativePath(_ path: String, field: String) throws(BuildSettingsError) {
        try checkArgument(path, field: field)
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw BuildSettingsError(field: field, reason: "リポジトリの直下からの相対パスではない")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0.isEmpty || $0 == ".." }) else {
            throw BuildSettingsError(field: field, reason: "`..` や空の要素を含む")
        }
    }

    /// 引数に渡す値。空・`-` 始まり・制御文字（改行など）を許さない
    static func checkArgument(_ value: String, field: String) throws(BuildSettingsError) {
        guard !value.isEmpty else { throw BuildSettingsError(field: field, reason: "空") }
        guard !value.hasPrefix("-") else { throw BuildSettingsError(field: field, reason: "`-` で始まる") }
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw BuildSettingsError(field: field, reason: "制御文字を含む")
        }
    }
}

/// ビルドの前にプロジェクトを作る道具（`.xcodeproj` をコミットしないリポジトリ）。
/// ワーカーは、ビルド・テスト・スクショのビルドの前に、作業場所の直下で決まったコマンドを流す（`AskHubBuild`）
public enum ProjectGenerator: String, Codable, Sendable, CaseIterable {
    /// XcodeGen。直下の `project.yml` から `xcodegen generate` で作る
    case xcodegen
}

/// どのテストを流すか（`xcodebuild test` の `-testPlan`・`-only-testing:`・`-skip-testing:`）
public struct TestSelection: Codable, Equatable, Sendable {
    /// スキームに含まれるテストプランの名前。nil ならスキームの既定
    public var testPlan: String?
    /// 流すテスト（`<ターゲット>`・`<ターゲット>/<型>`・`<ターゲット>/<型>/<メソッド>`）。空なら全部
    public var onlyTesting: [String]
    /// 流さないテスト（形は `onlyTesting` と同じ）
    public var skipTesting: [String]

    public init(testPlan: String? = nil, onlyTesting: [String] = [], skipTesting: [String] = []) {
        self.testPlan = testPlan
        self.onlyTesting = onlyTesting
        self.skipTesting = skipTesting
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        testPlan = try container.decodeIfPresent(String.self, forKey: .testPlan)
        onlyTesting = try container.decodeIfPresent([String].self, forKey: .onlyTesting) ?? []
        skipTesting = try container.decodeIfPresent([String].self, forKey: .skipTesting) ?? []
    }

    func validate(field: String) throws(BuildSettingsError) {
        if let testPlan {
            try BuildSettings.checkArgument(testPlan, field: "\(field).testPlan")
        }
        for test in onlyTesting {
            try BuildSettings.checkArgument(test, field: "\(field).onlyTesting")
        }
        for test in skipTesting {
            try BuildSettings.checkArgument(test, field: "\(field).skipTesting")
        }
    }
}

/// 設定の形の誤り
public struct BuildSettingsError: Error, Equatable, Sendable, CustomStringConvertible {
    public var field: String
    public var reason: String

    public init(field: String, reason: String) {
        self.field = field
        self.reason = reason
    }

    public var description: String { "ビルドの設定の \(field) が正しくない（\(reason)）" }
}
