import Foundation

/// アプリから出す、担当リポジトリの作成・削除の依頼（ラベル `repo-request` の Issue）。
///
/// 本文の先頭に機械が読める目印（JSON）を置き、続けて人が読める説明を置く:
///
/// ```html
/// <!-- ask-hub:repo-request {"action":"create","repository":"shilokuma-inc/foo-ios",...} -->
/// ```
///
/// - 作成（`create`）: 依頼 Issue は、作成を任せたい PC の担当リポジトリに作る。そのオーケストレーターがテンプレートから
///   リポジトリを作り、名前を変えて `develop` に push し、担当リポジトリに加える
/// - 削除（`remove`）: 依頼 Issue は、担当から外したいリポジトリそのものに作る。オーケストレーターが担当から外し、
///   選んだときはローカルの checkout・ループの worktree・DerivedData を消す。GitHub のリポジトリは消さない
///
/// 詳細は `docs/protocol.md` の「リポジトリの作成・削除」を参照
public enum RepositoryRequest: Sendable, Equatable {
    case create(NewRepository)
    case remove(RepositoryRemoval)

    /// 依頼 Issue に付けるラベル
    public static let labelName = AskHubLabel.repoRequest.rawValue

    /// 依頼の対象のリポジトリ（`owner/repo`）
    public var repository: String {
        switch self {
        case let .create(request): request.repository
        case let .remove(request): request.repository
        }
    }

    /// 送ってよい形か
    public var isValid: Bool {
        switch self {
        case let .create(request): request.isValid
        case let .remove(request): RepositoryName.isValidFullName(request.repository)
        }
    }

    /// Issue のタイトル
    public var title: String {
        switch self {
        case let .create(request): "【新規アプリ】\(request.repository)"
        case let .remove(request): "【担当の解除】\(request.repository)"
        }
    }

    /// Issue の本文（目印と、人が読む説明）
    public var body: String {
        let description: String
        switch self {
        case let .create(request):
            description = """
                ## 新しいアプリのリポジトリを作る

                | 項目 | 値 |
                | --- | --- |
                | リポジトリ | \(request.repository) |
                | テンプレート | \(request.template.title)（\(request.template.repository)） |
                | アプリ名 | \(request.appName) |
                | Bundle ID | \(request.bundleIdentifier) |
                | 担当 PC への clone | \(request.clonesToOrchestrator ? "する（担当リポジトリに加える）" : "しない（GitHub に作るだけ）") |
                """

        case let .remove(request):
            description = """
                ## 担当リポジトリから外す

                | 項目 | 値 |
                | --- | --- |
                | リポジトリ | \(request.repository) |
                | ローカルの削除 | \(request.deletesLocalFiles ? "する（checkout・ループの worktree・DerivedData）" : "しない") |
                | 未 push の変更の確認 | \(request.force ? "しない（強制）" : "する") |

                GitHub のリポジトリは削除しません。
                """
        }
        return """
            \(marker)
            \(description)

            担当 PC のオーケストレーターが処理し、結果をこの Issue にコメントします。（AskHub から作成）
            """
    }

    static let commentOpen = "<!--"
    static let commentClose = "-->"
    static let keyword = "ask-hub:repo-request"

    /// 本文の先頭に置く目印
    var marker: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // 自分の型の値だけなのでエンコードは失敗しない
        let encoded = (try? encoder.encode(Payload(self))).flatMap { String(bytes: $0, encoding: .utf8) } ?? "{}"
        // `>` をエスケープして、目印の終わり（`-->`）と取り違えないようにする
        let json = encoded.replacingOccurrences(of: ">", with: "\\u003e")
        return "\(Self.commentOpen) \(Self.keyword) \(json) \(Self.commentClose)"
    }

    /// 依頼 Issue の本文から依頼を読む。目印が先頭に無い・形式が崩れている・値が不正なら `nil`。
    /// author が信用できるかはここでは判定しない（`TrustedAuthors` を使う）
    public static func parse(_ body: String) -> Self? {
        let trimmed = body.drop { $0.isWhitespace || $0.isNewline }
        guard trimmed.hasPrefix(commentOpen), let closeRange = trimmed.range(of: commentClose) else {
            return nil
        }
        let inner = trimmed[trimmed.index(trimmed.startIndex, offsetBy: commentOpen.count)..<closeRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard inner.hasPrefix(keyword) else {
            return nil
        }
        let rest = inner.dropFirst(keyword.count)
        // `ask-hub:repo-requests` のような別の語を誤って拾わないよう、直後は空白に限る
        guard rest.first?.isWhitespace == true,
              let payload = try? JSONDecoder().decode(Payload.self, from: Data(rest.utf8)),
              let request = payload.request,
              request.isValid else {
            return nil
        }
        return request
    }

    /// 目印の JSON の形
    private struct Payload: Codable {
        let action: String
        let repository: String
        var template: String?
        var appName: String?
        var bundleIdentifier: String?
        var clone: Bool?
        var deleteLocal: Bool?
        var force: Bool?

        init(_ request: RepositoryRequest) {
            repository = request.repository
            switch request {
            case let .create(create):
                action = "create"
                template = create.template.repository
                appName = create.appName
                bundleIdentifier = create.bundleIdentifier
                clone = create.clonesToOrchestrator

            case let .remove(remove):
                action = "remove"
                deleteLocal = remove.deletesLocalFiles
                force = remove.force
            }
        }

        var request: RepositoryRequest? {
            switch action {
            case "create":
                guard let template = template.flatMap(NewRepository.Template.init(repository:)),
                      let appName else {
                    return nil
                }
                return .create(NewRepository(
                    repository: repository,
                    template: template,
                    appName: appName,
                    bundleIdentifier: bundleIdentifier ?? NewRepository.defaultBundleIdentifier(appName: appName),
                    clonesToOrchestrator: clone ?? true
                ))

            case "remove":
                return .remove(RepositoryRemoval(
                    repository: repository,
                    deletesLocalFiles: deleteLocal ?? false,
                    force: force ?? false
                ))

            default:
                return nil
            }
        }
    }
}

/// テンプレートから作る新しいアプリのリポジトリ
public struct NewRepository: Sendable, Equatable {
    /// 作成に使える GitHub のテンプレートリポジトリ。オーケストレーターはこの中のものだけを使う
    public enum Template: String, Sendable, CaseIterable, Identifiable {
        /// 通常のアプリ
        case standard = "shilokuma-inc/template-app-ios"
        /// クイズ系のアプリ
        case quiz = "shilokuma-inc/template-quiz-app-ios"

        public var id: String {
            rawValue
        }

        /// `owner/repo`
        public var repository: String {
            rawValue
        }

        /// 画面に出す名前
        public var title: String {
            switch self {
            case .standard: "通常"
            case .quiz: "クイズ"
            }
        }

        /// GitHub の名前は大文字・小文字を区別しない
        public init?(repository: String) {
            guard let template = Self.allCases.first(where: { $0.rawValue.caseInsensitiveCompare(repository) == .orderedSame }) else {
                return nil
            }
            self = template
        }
    }

    /// Bundle ID の接頭辞。テンプレートの `Configs/Project.xcconfig` と同じ
    public static let bundleIdentifierPrefix = "jp.shilokuma."

    /// `owner/repo`
    public var repository: String
    public var template: Template
    /// `scripts/rename.sh` に渡すプロジェクト名。英字で始まる英数字のみ
    public var appName: String
    public var bundleIdentifier: String
    /// 担当 PC に clone し、担当リポジトリに加えるか（`false` なら GitHub に作るだけ）
    public var clonesToOrchestrator: Bool

    public init(
        repository: String,
        template: Template,
        appName: String,
        bundleIdentifier: String,
        clonesToOrchestrator: Bool = true
    ) {
        self.repository = repository
        self.template = template
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.clonesToOrchestrator = clonesToOrchestrator
    }

    /// アプリ名から決まる既定の Bundle ID（テンプレートの rename.sh と同じ規則）
    public static func defaultBundleIdentifier(appName: String) -> String {
        bundleIdentifierPrefix + appName
    }

    /// 送ってよい形か。リポジトリ名・アプリ名・Bundle ID の形式を確かめる
    public var isValid: Bool {
        RepositoryName.isValidFullName(repository)
            && Self.isValidAppName(appName)
            && Self.isValidBundleIdentifier(bundleIdentifier)
    }

    /// 英字で始まる英数字のみ（rename.sh の条件）
    public static func isValidAppName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, CharacterSet.asciiLetters.contains(first) else {
            return false
        }
        return name.unicodeScalars.allSatisfy { CharacterSet.asciiAlphanumerics.contains($0) }
    }

    /// 英数字・ハイフンからなる要素を `.` でつないだもの（2 要素以上）
    public static func isValidBundleIdentifier(_ identifier: String) -> Bool {
        let parts = identifier.split(separator: ".", omittingEmptySubsequences: false)
        let allowed = CharacterSet.asciiAlphanumerics.union(CharacterSet(charactersIn: "-"))
        return parts.count >= 2 && parts.allSatisfy { part in
            !part.isEmpty && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

/// 担当から外すリポジトリ
public struct RepositoryRemoval: Sendable, Equatable {
    /// `owner/repo`
    public var repository: String
    /// ローカルの checkout・ループの worktree・DerivedData を消すか
    public var deletesLocalFiles: Bool
    /// 未コミット・未 push・stash の確認をせずに消すか
    public var force: Bool

    public init(repository: String, deletesLocalFiles: Bool, force: Bool = false) {
        self.repository = repository
        self.deletesLocalFiles = deletesLocalFiles
        self.force = force
    }
}

/// GitHub のリポジトリ名の形式
public enum RepositoryName {
    /// `owner/repo` の形で、どちらも GitHub で使える文字（英数字と `-` `_` `.`）だけか。
    /// 目印からシェルのスクリプトの引数に渡すので、受け付ける文字を絞る
    public static func isValidFullName(_ fullName: String) -> Bool {
        let parts = fullName.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet.asciiAlphanumerics.union(CharacterSet(charactersIn: "-_."))
        return parts.count == 2 && parts.allSatisfy { part in
            !part.isEmpty && part != "." && part != ".." && !part.hasPrefix("-")
                && part.unicodeScalars.allSatisfy { allowed.contains($0) }
        }
    }
}

extension CharacterSet {
    /// ASCII の英字（`CharacterSet.letters` は全角文字なども含むため）
    static let asciiLetters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
    /// ASCII の英数字
    static let asciiAlphanumerics = asciiLetters.union(CharacterSet(charactersIn: "0123456789"))
}
