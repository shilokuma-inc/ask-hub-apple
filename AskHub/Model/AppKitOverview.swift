import Foundation

/// 共通リポジトリ app-kit の様子（状態リポジトリの `app-kit.json`）。リポジトリのタブの上の「app-kit」の画面に出す
/// （`docs/renewal/app-kit.md` の「版を広げる」）
struct AppKitOverview: Hashable {
    /// app-kit の版 1 つ
    struct Release: Identifiable, Hashable {
        var id: String { version }
        /// `v1.0.1` の形
        var version: String
        /// タグが指すコミット。広げるときは、見たときのこのコミットに結びつける
        var ref: String
        /// `CHANGELOG.md` のその版の節（Markdown）。読めなければ nil
        var changes: String?
        var foundAt: Date
    }

    /// 広げている・最後に広げた版
    struct Rollout: Hashable {
        var version: String
        var ref: String
        var state: AppKitRolloutState
        /// 試しの 1 本（`owner/name`）
        var pilot: String
        var targets: [Target]
        var problem: String?
        var startedAt: Date
        var updatedAt: Date

        /// 入れた相手の数（PR が要らなかったものも）
        var doneCount: Int { targets.count { $0.state == .done } }
    }

    /// 版を広げる相手 1 つの様子
    struct Target: Identifiable, Hashable {
        var id: String { repository.lowercased() }
        /// `owner/name`
        var repository: String
        var isTemplate: Bool
        var state: AppKitTargetState
        var pullRequest: Int?
        var problem: String?
        var updatedAt: Date

        /// GitHub の PR の画面
        var pullRequestURL: URL? {
            pullRequest.flatMap { URL(string: "https://github.com/\(repository)/pull/\($0)") }
        }
    }

    /// テンプレートに入っている版
    struct Template: Identifiable, Hashable {
        var id: String { repository.lowercased() }
        var repository: String
        /// まだ入れ替えていなければ nil
        var installed: AppKitInstallation?
    }

    /// 最後にタグを読んだ時刻
    var checkedAt: Date?
    /// 最後にタグを読めなかった理由
    var problem: String?
    /// 見つけた版（新しい順）
    var releases: [Release]
    /// 対象に加えるとき・準備をやり直すときに入れる版
    var adoptionVersion: String?
    var rollout: Rollout?
    var templates: [Template]
    /// 最後に送った「広げる」「やめる」を司令塔が断った理由。無ければ nil
    var rejection: String?

    var latest: Release? { releases.first }

    /// 広げられる新しい版（一番新しい版で、まだ広げていない・広げるのをやめていない）。無ければ nil
    var newRelease: Release? {
        guard let latest else { return nil }
        guard let rollout else { return latest }
        return Self.isNewer(latest.version, than: rollout.version) ? latest : nil
    }

    /// 版の新しさを数で比べる（`v1.10.0` は `v1.9.0` より新しい）
    static func isNewer(_ version: String, than other: String) -> Bool {
        let numbers = { (text: String) in text.dropFirst().split(separator: ".").map { Int($0) ?? 0 } }
        return numbers(other).lexicographicallyPrecedes(numbers(version))
    }

    /// 広げるのを始められるか（ほかの版を広げている途中でない）
    func canRollOut(_ release: Release) -> Bool {
        guard let rollout, rollout.version != release.version else { return true }
        return rollout.state != .running && rollout.state != .failed
    }
}

/// 広げる様子
enum AppKitRolloutState: Hashable {
    case running
    /// 失敗して止めた。もう一度試すか、やめる
    case failed
    case finished
    /// 人がやめた
    case stopped
}

/// 版を広げる相手 1 つの様子
enum AppKitTargetState: Hashable {
    /// PR を出して、チェックを待っている
    case open
    /// マージして、develop の Build を待っている（試しの 1 本）
    case verifying
    case done
    case failed
    /// 出さなかった（まだ入れ替えていない・major が違う など）
    case skipped
    /// やめたので PR を閉じた
    case stopped
}

/// 対象のリポジトリ（かテンプレート）に入っている app-kit の版（`repo.json` の `appKit`）
struct AppKitInstallation: Hashable {
    /// タグ（`v1.0.0`）。タグの無いコミットを呼んでいれば nil
    var version: String?
    var ref: String
    var installedAt: Date?
    /// 写すファイル・`.github/app-kit.json` のずれ（人が読む文）。ずれていなければ空
    var drift: [String] = []
    var driftFoundAt: Date?

    /// 画面に出す版の名前（タグが無ければコミットの先頭）
    var versionLabel: String { version ?? String(ref.prefix(7)) }

    /// 入っている版が、ほかの版より古い（タグの無いコミットは古いとみなす）
    func isOlder(than other: String) -> Bool {
        version.map { AppKitOverview.isNewer(other, than: $0) } ?? true
    }
}

/// 対象のリポジトリの app-kit の様子（入っている版と、広げている版のこのリポジトリの PR）
struct RepositoryAppKit: Hashable {
    /// 入っている版。まだ入れ替えていなければ nil（入れ替えは「加えるときの準備」の PR で行う）
    var installed: AppKitInstallation?
    /// 広げている・最後に広げた版（`v1.0.1`）。広げていなければ nil
    var rolloutVersion: String?
    /// その版の、このリポジトリの様子。まだ確かめていなければ nil
    var rolloutTarget: AppKitOverview.Target?
}

extension ClientSnapshot {
    /// 版を広げると PR を出す相手の数（入れ替え済みで、その版より古い版が入っているリポジトリとテンプレート）
    func appKitRolloutCount(_ release: AppKitOverview.Release) -> Int {
        let installed = repositories.compactMap { $0.appKit?.installed } + (appKit?.templates.compactMap(\.installed) ?? [])
        return installed.count { $0.isOlder(than: release.version) }
    }
}

extension AppKitOverview {
    /// 変更点（Markdown）の最初の 1 行を、一覧の 2 行目に出す平文にする。箇条書き・見出し・番号・引用の記号（後ろに空白が続くものだけ）と、
    /// コード・強調の記号を外す。中身のある行が無ければ nil
    static func plainSummary(of changes: String) -> String? {
        for line in changes.split(separator: "\n") {
            var text = line.trimmingCharacters(in: .whitespaces)
            // 「- -1 を返す」の負の符号のように、記号の後ろに空白が無いものは中身として残す
            while let range = text.range(of: #"^([-*+>]|#{1,6}|\d+[.)])\s+"#, options: .regularExpression) {
                text.removeSubrange(range)
            }
            // 記号だけの行（空の箇条書き）は中身が無い
            if text.range(of: #"^([-*+>]|#{1,6}|\d+[.)])$"#, options: .regularExpression) != nil {
                continue
            }
            for pattern in emphasisPatterns {
                text = text.replacingOccurrences(of: pattern, with: "$2", options: .regularExpression)
            }
            text = text.replacingOccurrences(of: #"`([^`]*)`"#, with: "$1", options: .regularExpression)
            text = text.trimmingCharacters(in: .whitespaces)
            if !text.isEmpty {
                return text
            }
        }
        return nil
    }

    /// 強調（`**太字**`・`__太字__`・`*斜体*`・`_斜体_`）。語の途中の記号（`snake_case`・`a*b`）は強調とみなさない
    private static let emphasisPatterns = [
        #"(\*\*|__)(?!\s)(.+?)(?<!\s)\1"#,
        #"(?<![\p{L}\p{N}*])(\*)(?![\s*])(.+?)(?<![\s*])\*(?![\p{L}\p{N}*])"#,
        #"(?<![\p{L}\p{N}_])(_)(?![\s_])(.+?)(?<![\s_])_(?![\p{L}\p{N}_])"#
    ]
}

// MARK: - あなたの番

extension InboxBuilder {
    /// app-kit の新しい版（時間のあるときに）と、広げる途中で止まったこと（進行が止まっています）
    static func appKitItems(_ snapshot: ClientSnapshot) -> [InboxItem] {
        guard let appKit = snapshot.appKit else {
            return []
        }
        var items: [InboxItem] = []
        if let rollout = appKit.rollout, rollout.state == .failed {
            let detail = rollout.problem ?? "止まった相手を確かめて、もう一度試すか、やめる"
            let title = "app-kit \(rollout.version) を広げる途中で止まりました"
            items.append(appKitItem(id: "rollout", urgency: .blocking, title: title, detail: detail, since: rollout.updatedAt))
        }
        // 入れた相手がまだ無い（入れ替える前）なら、広げる相手がいないので知らせない
        if let release = appKit.newRelease, appKit.canRollOut(release), snapshot.appKitRolloutCount(release) > 0 {
            let detail = release.changes.flatMap { AppKitOverview.plainSummary(of: $0) } ?? "変更点を見て広げる"
            let title = "app-kit \(release.version) を広げる"
            let id = "release/\(release.version)"
            items.append(appKitItem(id: id, urgency: .whenFree, title: title, detail: detail, since: release.foundAt))
        }
        for template in appKit.templates {
            guard let installed = template.installed, !installed.drift.isEmpty else { continue }
            let detail = "\(template.repository) · " + installed.drift.joined(separator: "・")
            let since = installed.driftFoundAt ?? appKit.checkedAt ?? .distantPast
            let title = "テンプレートの app-kit のずれを直す"
            items.append(appKitItem(id: "drift/\(template.id)", urgency: .whenFree, title: title, detail: detail, since: since))
        }
        return items
    }

    /// 対象のリポジトリの app-kit のずれ（時間のあるときに）
    static func appKitDriftItem(_ repository: TargetRepository) -> InboxItem? {
        guard let installed = repository.appKit?.installed, !installed.drift.isEmpty else {
            return nil
        }
        return InboxItem(
            id: "repository/\(repository.id)/app-kit",
            urgency: .whenFree,
            kind: .appKit,
            repositoryID: repository.id,
            title: "app-kit のずれを直す",
            context: repository.appName,
            detail: installed.drift.joined(separator: "・"),
            since: installed.driftFoundAt ?? .distantPast,
            route: .repository(repository.id),
            targets: [.repository(repository.id)]
        )
    }

    private static func appKitItem(id: String, urgency: InboxItem.Urgency, title: String, detail: String, since: Date) -> InboxItem {
        InboxItem(
            id: "app-kit/\(id)",
            urgency: urgency,
            kind: .appKit,
            repositoryID: nil,
            title: title,
            context: "app-kit",
            detail: detail,
            since: since,
            route: .appKit,
            targets: [.appKit]
        )
    }
}
