import AskHubProtocol
import AskHubPullRequests
import Foundation

/// 対象に加えるときに直すワークフローのファイルを決める（`docs/renewal/operations.md` の「既存のリポジトリを移すとき」）。
///
/// - 今の仕組みのワークフロー（`close-goal-discussion.yml`・ralph-kit を呼ぶもの）は外す
/// - 待つチェック（`childChecks`・`finalChecks`）を出すワークフローの、`push`・`pull_request` の `paths`・`paths-ignore` を外す。
///   絞っていると、ドキュメントだけの子 PR でチェックが出ず、ワーカーが待ちきれずに止まり、ルールセットで必須にしたチェックも出ずにマージできない
///
/// YAML は行で読む（Swift に YAML の部品が無いため）。決まった形（`on:` の下のイベントの下のキー）だけを外し、ほかの行は変えない
enum WorkflowSetupEditor {
    /// 直すファイル（パス → 新しい中身。外すファイルは nil）と、直したところ
    struct Plan: Equatable {
        var changes: [String: String?] = [:]
        var summary: [WorkflowChange] = []
        /// どのワークフローのジョブ（id か表示名）にも見つからない待つチェック。絞りを人が確かめる
        var unresolvedJobs: [String] = []

        var isEmpty: Bool { changes.isEmpty }
    }

    static func plan(_ files: [WorkflowFile], waitedJobs: Set<String>) -> Plan {
        var plan = Plan()
        var found: Set<String> = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            if isLegacy(file) {
                plan.changes[file.path] = .some(nil)
                plan.summary.append(.init(kind: .removeLegacy, path: file.path))
                continue
            }
            let jobs = jobIDs(in: file.text).union(jobNames(in: file.text))
            found.formUnion(jobs)
            if !waitedJobs.isDisjoint(with: jobs), let edited = removingPathFilters(file.text) {
                plan.changes[file.path] = .some(edited)
                plan.summary.append(.init(kind: .removePathFilters, path: file.path))
            }
        }
        plan.unresolvedJobs = waitedJobs.subtracting(found).sorted()
        return plan
    }

    /// 待つチェックの名前から、それを出すジョブの id（`build / build` の前の `build`。再利用ワークフローを呼ぶジョブの id）
    static func waitedJobs(of build: RepositoryFile.Build?) -> Set<String> {
        let checks = build.map { $0.childChecks + $0.finalChecks } ?? ProtectionPolicy.defaultRequiredChecks
        let jobs = checks.compactMap { check in check.components(separatedBy: " / ").first?.trimmingCharacters(in: .whitespaces) }
        return Set(jobs.filter { !$0.isEmpty })
    }

    /// 今の仕組みのワークフローか。決まった名前のファイルか、`uses:` で今の仕組み（ralph-kit）を呼ぶもの。
    /// コメントやほかの値に目印の文字があるだけでは外さない
    static func isLegacy(_ file: WorkflowFile) -> Bool {
        if SetupPolicy.legacyWorkflowNames.contains(file.name) { return true }
        return file.text.components(separatedBy: "\n").contains { line in
            guard let target = usesValue(of: line)?.lowercased() else { return false }
            return SetupPolicy.legacyMarkers.contains { target.contains($0) }
        }
    }

    /// `uses:`（ステップのリストの `- uses:` も）の値。行の終わりのコメントは除く
    private static func usesValue(of line: String) -> String? {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("- ") { trimmed = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        guard key(of: trimmed) == "uses" else { return nil }
        let value = trimmed.dropFirst("uses:".count)
        return String(value.components(separatedBy: " #").first ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// トップレベルの `jobs:` の下のジョブの id
    static func jobIDs(in text: String) -> Set<String> {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { key(of: $0) == "jobs" && indent(of: $0) == 0 }) else { return [] }
        var jobIndent: Int?
        var ids: Set<String> = []
        for line in lines[(start + 1)...] where !isBlankOrComment(line) {
            let level = indent(of: line)
            if level == 0 { break }
            if jobIndent == nil { jobIndent = level }
            if level == jobIndent, let id = key(of: line) { ids.insert(id) }
        }
        return ids
    }

    /// ジョブの表示名（`jobs.<id>.name`）。式（`${{ … }}`）のものは読めないので除く
    static func jobNames(in text: String) -> Set<String> {
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { key(of: $0) == "jobs" && indent(of: $0) == 0 }) else { return [] }
        var jobIndent: Int?
        var fieldIndent: Int?
        var names: Set<String> = []
        for line in lines[(start + 1)...] where !isBlankOrComment(line) {
            let level = indent(of: line)
            if level == 0 { break }
            if jobIndent == nil { jobIndent = level }
            if level == jobIndent {
                fieldIndent = nil
                continue
            }
            if fieldIndent == nil { fieldIndent = level }
            guard level == fieldIndent, key(of: line) == "name" else { continue }
            let name = unquoted(value(of: line))
            if !name.isEmpty, !name.contains("${{") { names.insert(name) }
        }
        return names
    }

    /// `on:` の下の `push`・`pull_request` の `paths`・`paths-ignore` を、その上に続くコメントの行と一緒に外す。外すものが無ければ nil
    static func removingPathFilters(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        guard let on = lines.firstIndex(where: { indent(of: $0) == 0 && ["on", "\"on\"", "'on'"].contains(key(of: $0) ?? "") }) else {
            return nil
        }
        var removed = false
        var index = on + 1
        var event: (name: String, indent: Int)?
        while index < lines.count {
            let line = lines[index]
            if isBlankOrComment(line) {
                index += 1
                continue
            }
            let level = indent(of: line)
            if level == 0 { break }
            if let current = event, level > current.indent, ["push", "pull_request"].contains(current.name),
               let name = key(of: line), ["paths", "paths-ignore"].contains(name) {
                let end = blockEnd(after: index, level: level, in: lines)
                let start = commentStart(before: index, at: level, in: lines)
                lines.removeSubrange(start..<end)
                removed = true
                index = start
                continue
            }
            if event == nil || level <= event?.indent ?? 0 { event = key(of: line).map { ($0, level) } }
            index += 1
        }
        return removed ? lines.joined(separator: "\n") : nil
    }

    /// `index` の行（キー）に続く値の行（より深い行と、値の無いキーなら同じ深さに書いたリストの値 `- …`）の終わり
    private static func blockEnd(after index: Int, level: Int, in lines: [String]) -> Int {
        let takesList = value(of: lines[index]).isEmpty
        let inside = { (line: String) in
            indent(of: line) > level
                || (takesList && indent(of: line) == level && line.trimmingCharacters(in: .whitespaces).hasPrefix("-"))
        }
        var end = index + 1
        while end < lines.count, isBlankOrComment(lines[end]) || inside(lines[end]) {
            // 空の行の後に値でない行が来るなら、空の行は残す
            if lines[end].trimmingCharacters(in: .whitespaces).isEmpty,
               let next = lines[(end + 1)...].first(where: { !isBlankOrComment($0) }), !inside(next) {
                break
            }
            end += 1
        }
        return end
    }

    /// `index` の行のすぐ上に、同じ深さで続くコメントの行の始まり
    private static func commentStart(before index: Int, at level: Int, in lines: [String]) -> Int {
        var start = index
        while start > 0 {
            let previous = lines[start - 1]
            guard previous.trimmingCharacters(in: .whitespaces).hasPrefix("#"), indent(of: previous) == level else { break }
            start -= 1
        }
        return start
    }

    private static func indent(of line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func isBlankOrComment(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed.hasPrefix("#")
    }

    /// `key: value` の行の値（行の終わりのコメントは除く）。値が無ければ空
    private static func value(of line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let colon = trimmed.firstIndex(of: ":") else { return "" }
        let after = String(trimmed[trimmed.index(after: colon)...])
        let value = after.hasPrefix(" #") ? "" : after.components(separatedBy: " #").first ?? ""
        return value.trimmingCharacters(in: .whitespaces)
    }

    private static func unquoted(_ text: String) -> String {
        for quote in ["\"", "'"] where text.count >= 2 && text.hasPrefix(quote) && text.hasSuffix(quote) {
            return String(text.dropFirst().dropLast())
        }
        return text
    }

    /// `key:`（値があってもよい）の行のキー。リストの値（`- …`）やキーの無い行は nil
    private static func key(of line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        let after = trimmed[trimmed.index(after: colon)...]
        guard !name.isEmpty, after.isEmpty || after.first == " " else { return nil }
        return name
    }
}
