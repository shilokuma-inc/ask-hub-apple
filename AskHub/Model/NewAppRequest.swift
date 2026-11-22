import AskHubProtocol
import Foundation

/// テンプレートから作る新しいアプリ（依頼の画面の「新しいアプリ」）。司令塔が管理用のトークンで作り、対象に加える
struct NewAppRequest: Hashable {
    var template: RepositoryTemplate = .ios
    /// 作る先の持ち主（管理用のトークンを置いた持ち主から選ぶ）
    var owner = ""
    var name = ""
    var appName = ""
    var bundleId = ""
    var visibility: RepositoryVisibility = .public

    var fullName: String { "\(owner)/\(name)" }
    /// 作った後の対象のリポジトリの id
    var repositoryID: TargetRepository.ID { fullName.lowercased() }
    var repository: RepositoryFullName? { RepositoryFullName(rawValue: fullName) }

    /// 送れないわけ。送れるなら nil
    var problem: String? {
        if owner.isEmpty { return "作る先の持ち主を選んでください" }
        if name.isEmpty { return "リポジトリの名前を入れてください" }
        if repository == nil { return "リポジトリの名前は英数字と . _ - で入れてください" }
        if !CreateRepositoryIntent.isAppName(appName) { return "アプリ名は英字で始まる英数字で入れてください（Swift のモジュール名になります）" }
        if !CreateRepositoryIntent.isBundleId(bundleId) { return "Bundle ID は jp.shilokuma.MyApp のような形で入れてください" }
        return nil
    }

    /// リポジトリの名前から決まるアプリ名の案（`kobuta-quiz-ios` → `KobutaQuiz`）。プラットフォームの接尾辞は落とす
    static func suggestedAppName(from repositoryName: String) -> String {
        let platformWords: Set<String> = ["ios", "visionos", "vision", "apple", "macos", "app"]
        var words = repositoryName.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        while let last = words.last, words.count > 1, platformWords.contains(last.lowercased()) {
            words.removeLast()
        }
        let joined = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        // 英字で始まる英数字だけを残す（日本語などは使えない）
        let ascii = String(joined.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0)) })
        return String(ascii.drop { !$0.isLetter }.prefix(CreateRepositoryIntent.maximumAppNameLength))
    }

    /// テンプレートの既定の持ち主（テンプレートのある organization）
    static func preferredOwner(for template: RepositoryTemplate) -> String {
        template.repository.owner
    }
}
