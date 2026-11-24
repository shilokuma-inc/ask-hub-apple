import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 対象に加えるときの準備の PR に足す、app-kit への入れ替えの中身を決める（`docs/renewal/app-kit.md` の「初めての入れ替え」）。
///
/// - 写すファイルを版の中身にする（`unmanaged` は除く。もう同じ中身なら変えない）
/// - `.github/app-kit.json` が無ければ、ビルドの設定とリポジトリのファイルから作る（あれば変えず、`unmanaged` を読む）
/// - `manifest.json` の `replaces` にあるファイルを外す（`keepIfPresent` のどれかがあれば残す）
/// - 待つチェックのうち、入れ替えた後に出ない名前（`Build` など）を、入れ替えた後の名前に付け替える
///
/// 入れ替えられないわけがあれば、何も変えずにわけだけを返す（準備のほかの直しは続ける）
enum AppKitAdoptionPlanner {
    struct Plan: Equatable {
        /// 直すファイル（パス → 新しい中身。外すファイルは nil）
        var changes: [String: String?] = [:]
        var summary: [WorkflowChange] = []
        var adoption: AppKitAdoption?
        /// 入れ替えられないわけ（人が読む文）。あれば `changes` は空
        var problems: [String] = []
    }

    /// 外すワークフローにしか無い手順を、1 つのファイルで出す数の上限
    static let maximumSteps = 50

    /// - Parameters:
    ///   - files: base の先頭のコミットのファイル（tree）
    ///   - texts: 中身を読んだファイル（パス → 中身）。外すファイルと、あれば `.github/app-kit.json`
    ///   - waitedChecks: 待つチェック（ビルドの設定の `childChecks`・`finalChecks` と、保護の必須のチェック）
    static func plan(
        release: AppKitRelease,
        files: [TreeFile],
        texts: [String: String],
        build: RepositoryFile.Build?,
        waitedChecks: [String]
    ) -> Plan {
        let paths = Dictionary(files.map { ($0.path, $0.sha) }) { first, _ in first }
        var plan = Plan()
        var unmanaged: Set<String> = []
        if paths[AppKitPolicy.configPath] != nil {
            unmanaged = Set(existingUnmanaged(texts[AppKitPolicy.configPath]))
        } else {
            switch config(build: build, files: Array(paths.keys), texts: texts) {
            case let .success(text):
                plan.changes[AppKitPolicy.configPath] = .some(text)
                plan.summary.append(.init(kind: .adoptAppKit, path: AppKitPolicy.configPath))
            case let .failure(problem):
                return Plan(problems: [problem.description])
            }
        }
        for path in release.manifest.managed where !unmanaged.contains(path) {
            guard let text = release.managed[path], paths[path] != GitBlob.sha(of: text) else { continue }
            plan.changes[path] = .some(text)
            plan.summary.append(.init(kind: .adoptAppKit, path: path))
        }
        for replace in release.manifest.replaces where paths[replace.path] != nil {
            if replace.keepIfPresent?.contains(where: { paths[$0] != nil }) == true { continue }
            plan.changes[replace.path] = .some(nil)
            let text = texts[replace.path]
            plan.summary.append(.init(
                kind: .removeReplaced,
                path: replace.path,
                lines: text.map(lineCount),
                steps: text.flatMap { replace.path.hasPrefix(".github/workflows/") ? onlySteps(in: $0, release: release) : nil }
            ))
        }
        let renames: [CheckRename]
        switch renamedChecks(waitedChecks, produced: release.buildChecks) {
        case let .success(made): renames = made
        case let .failure(problem): return Plan(problems: [problem.description])
        }
        guard !plan.changes.isEmpty || !renames.isEmpty else { return Plan() }
        plan.adoption = AppKitAdoption(version: release.pin.version, ref: release.pin.ref, renamedChecks: renames.isEmpty ? nil : renames)
        return plan
    }

    /// 外すワークフローの手順のうち、app-kit の再利用ワークフローに同じ名前の手順が無いもの。無ければ nil
    static func onlySteps(in text: String, release: AppKitRelease) -> [String]? {
        let names = WorkflowSteps.names(in: text).subtracting(release.steps).sorted().prefix(maximumSteps)
        let steps = names.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(200))) }
        return steps.isEmpty ? nil : steps
    }

    static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.split(separator: "\n", omittingEmptySubsequences: false).count - (text.hasSuffix("\n") ? 1 : 0)
    }

    /// 待つチェックのうち、入れ替えた後に出ない名前を、入れ替えた後の名前に付け替える。入れ替えた後の名前が 1 つに決まらなければ、わけを返す
    static func renamedChecks(_ waited: [String], produced: [String]) -> Result<[CheckRename], AdoptionProblem> {
        var seen: Set<String> = []
        let missing = waited.filter { !produced.contains($0) && seen.insert($0).inserted }
        guard !missing.isEmpty else { return .success([]) }
        guard produced.count == 1, let name = produced.first else {
            return .failure(.init(
                description: "待つチェック \(missing.joined(separator: "・")) が、app-kit に入れ替えた後に出ない（入れ替えた後のチェック: "
                    + "\(produced.isEmpty ? "無し" : produced.joined(separator: "・"))）。ビルドの設定の待つチェックを人が直す"
            ))
        }
        return .success(missing.map { CheckRename(from: $0, to: name) })
    }

    /// 付け替えた後のチェックの名前（並びを保ち、重なりを除く）
    static func renaming(_ checks: [String], with renames: [CheckRename]) -> [String] {
        var seen: Set<String> = []
        return checks.map { check in renames.first { $0.from == check }?.to ?? check }.filter { seen.insert($0).inserted }
    }

    /// 今の `.github/app-kit.json` の `unmanaged`。読めなければ空
    static func existingUnmanaged(_ text: String?) -> [String] {
        struct Config: Decodable {
            let unmanaged: [String]?
        }
        guard let data = text?.data(using: .utf8), let config = try? JSONDecoder().decode(Config.self, from: data) else { return [] }
        return config.unmanaged ?? []
    }

    struct AdoptionProblem: Error, Equatable, CustomStringConvertible {
        var description: String
    }

    /// `.github/app-kit.json` の中身（app-kit の `schema/app-kit.schema.json`）。ビルドの設定から作り、UI テストのターゲットと
    /// `GoogleService-Info.plist` の書き出し先はリポジトリのファイルから見つける
    static func config(build: RepositoryFile.Build?, files: [String], texts: [String: String]) -> Result<String, AdoptionProblem> {
        guard let xcode = build?.xcode else {
            return .failure(.init(description: "ビルドの設定が無いので、app-kit の設定（.github/app-kit.json）を作れない。先にビルドの設定を入れる"))
        }
        guard matches(xcode.project, #"^[A-Za-z0-9_][A-Za-z0-9_.+/-]*\.xcodeproj$"#) else {
            return .failure(.init(description: "ビルドの設定のプロジェクト \(xcode.project) が .xcodeproj でないので、app-kit に入れ替えられない"))
        }
        guard matches(xcode.scheme, #"^[A-Za-z0-9_][A-Za-z0-9_.+-]*$"#) else {
            return .failure(.init(description: "ビルドの設定のスキーム \(xcode.scheme) の形が app-kit の設定に合わない"))
        }
        var platforms: [String] = []
        for destination in xcode.destinations {
            let name = switch destination {
            case .macOS: "macOS"
            case let .simulator(simulator): simulator.platform.rawValue
            }
            if !platforms.contains(name) { platforms.append(name) }
        }
        var lines = [
            "  \"v\": 1",
            "  \"project\": \(quoted(xcode.project))",
            "  \"scheme\": \(quoted(xcode.scheme))",
            "  \"platforms\": [\(platforms.map(quoted).joined(separator: ", "))]"
        ]
        if xcode.generate == .xcodegen { lines.append("  \"generate\": \"xcodegen\"") }
        lines.append("  \"uiTests\": \(uiTestTarget(scheme: xcode.scheme, files: files).map(quoted) ?? "null")")
        if let plist = googleServiceInfo(in: texts) { lines.append("  \"archive\": { \"googleServiceInfo\": \(quoted(plist)) }") }
        return .success("{\n\(lines.joined(separator: ",\n"))\n}\n")
    }

    /// UI テストのターゲット（直下の `…UITests` のフォルダ）。スキームと同じ名前のものを先に選ぶ。決まらなければ nil
    static func uiTestTarget(scheme: String, files: [String]) -> String? {
        let folders = Set(files.compactMap { path -> String? in
            let parts = path.split(separator: "/")
            guard parts.count > 1, parts[0].hasSuffix("UITests") else { return nil }
            return String(parts[0])
        })
        if folders.contains("\(scheme)UITests") { return "\(scheme)UITests" }
        let candidates = folders.filter { matches($0, #"^[A-Za-z0-9_][A-Za-z0-9_.+-]*$"#) }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// 外すワークフローが Secret `GOOGLE_SERVICE_INFO_PLIST_BASE64` を書き出していた `GoogleService-Info.plist` のパス
    static func googleServiceInfo(in texts: [String: String]) -> String? {
        for (path, text) in texts.sorted(by: { $0.key < $1.key })
        where path.hasPrefix(".github/workflows/") && text.contains("GOOGLE_SERVICE_INFO_PLIST_BASE64") {
            let pattern = #"[A-Za-z0-9_][A-Za-z0-9_.+/-]*/GoogleService-Info\.plist"#
            if let range = text.range(of: pattern, options: .regularExpression) { return String(text[range]) }
        }
        return nil
    }

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil && !text.contains("\n")
    }

    private static func quoted(_ text: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let data = (try? encoder.encode(text)) ?? Data("\"\"".utf8)
        return String(bytes: data, encoding: .utf8) ?? "\"\""
    }
}

/// 呼ぶ側のワークフローが呼んでいる app-kit の版のコミット（`uses: shilokuma-inc/app-kit/.github/workflows/app-build.yml@<コミット>`）
enum AppKitCaller {
    static func ref(in files: [WorkflowFile]) -> String? {
        guard let build = files.first(where: { $0.path == ".github/workflows/build.yml" }) else { return nil }
        let pattern = "\(AppKitPolicy.repository.rawValue)/.github/workflows/app-build.yml@"
        for line in build.text.components(separatedBy: "\n") {
            guard let range = line.range(of: pattern) else { continue }
            let ref = String(line[range.upperBound...].prefix(40))
            if AttemptFile.isCommitSHA(ref) { return ref }
        }
        return nil
    }

    /// 呼ぶ側のワークフローが再利用ワークフローに渡す app-kit のコミット（`app-kit-ref: '<コミット>'`）。無ければ nil
    static func kitRef(in text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("app-kit-ref:") else { continue }
            let value = trimmed.dropFirst("app-kit-ref:".count).trimmingCharacters(in: CharacterSet(charactersIn: " '\""))
            let ref = String(value.prefix(40))
            if AttemptFile.isCommitSHA(ref) { return ref }
        }
        return nil
    }
}
