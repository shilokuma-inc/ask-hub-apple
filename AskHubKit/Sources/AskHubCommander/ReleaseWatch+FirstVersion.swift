import AskHubProtocol
import Foundation

// 初めての版（配信中の版が無い）の掲載文の今の文（`docs/renewal/release.md` の「掲載文」）
extension ReleaseWatch {
    /// 初めての版の、編集できる版（プラットフォームごとに 1 つ。記録の版の枠を先に、無ければ同じ番号の編集できる版。iOS を先に並べる）
    static func editableVersions(_ versions: [AppStoreVersionInfo], of file: SubmissionFile) -> [AppStoreVersionInfo] {
        let slots = Set((file.appStoreVersions ?? []).map(\.id))
        let editable = versions.filter { $0.isEditable && (slots.contains($0.id) || $0.versionString == file.version.rawValue) }
            .sorted { lhs, rhs in
                let left = (lhs.platform == .iOS ? 0 : 1, slots.contains(lhs.id) ? 0 : 1)
                let right = (rhs.platform == .iOS ? 0 : 1, slots.contains(rhs.id) ? 0 : 1)
                return left < right
            }
        var chosen: [AppStoreVersionInfo] = []
        for version in editable where !chosen.contains(where: { $0.platform == version.platform }) { chosen.append(version) }
        return chosen
    }

    /// プラットフォームごとの今の文を 1 つにする。どの版にも同じ文が入っている欄だけを残す（片方が空・文が違う欄は空とみなし、案で書く。
    /// 人が確かめた案は、審査に出すときにすべてのプラットフォームの版に書かれる）。言語は、どれかの版にあるものすべて
    static func commonListing(_ listings: [[ListingText]]) -> [ListingText] {
        var locales: [String] = []
        for listing in listings { for text in listing where !locales.contains(text.locale) { locales.append(text.locale) } }
        return locales.map { locale in
            var text = ListingText(locale: locale)
            for field in ListingText.Field.allCases {
                let values = listings.map { $0.first { $0.locale == locale }?[field] }
                if let value = values.first.flatMap(\.self), !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   values.allSatisfy({ $0 == value }) {
                    text[field] = value
                }
            }
            return text
        }
    }
}
