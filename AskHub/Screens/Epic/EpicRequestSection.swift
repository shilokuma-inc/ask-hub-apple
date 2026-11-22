import SwiftUI

/// epic の元の依頼（要約・内容・添付の数）。「このリリースを直す」依頼なら、直すリリースへの行を出す
struct EpicRequestSection: View {
    let epic: Epic

    var body: some View {
        CardSection("依頼") {
            Text(epic.request.summary).rowFont(.title)
            if let release = epic.release {
                // 「このリリースを直す」依頼は、作業ブランチを release ブランチから作り、最終 PR を release ブランチに向ける
                NavigationLink(value: AppRoute.submission(repositoryID: epic.repositoryID, version: release)) {
                    Label("リリース \(release) を直す（release/\(release) に入れる）", systemImage: "wrench.and.screwdriver")
                }
                .accessibilityIdentifier("epic.release")
            }
            Text(epic.request.body).foregroundStyle(.secondary)
            if epic.request.attachmentCount > 0 {
                Label("添付 \(epic.request.attachmentCount)", systemImage: "paperclip")
                    .foregroundStyle(.secondary)
            }
        }
    }
}
