import SwiftUI

/// ゴールの「別のリポジトリへの依頼の案」。この epic では作らないので、AskHub の対象のリポジトリなら、案から依頼の下書きを書ける（epic は待たない）
struct OutsideRequestsSection: View {
    let requests: [Goal.OutsideRequest]

    @Environment(ClientStore.self) private var store
    @State private var draft: RequestDraft?

    var body: some View {
        CardSection {
            ForEach(requests, id: \.self) { request in
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.title).rowFont(.title)
                    Text(repositoryLabel(request))
                        .appFont(.caption)
                        .foregroundStyle(.secondary)
                    Text(request.body).foregroundStyle(.secondary)
                    if let repository = store.repository(request.repositoryID) {
                        Button("この案で依頼を書く", systemImage: "square.and.pencil") {
                            draft = RequestDraft(repositoryID: repository.id, summary: request.title, body: request.body)
                        }
                        .buttonStyle(.borderless)
                    } else {
                        Text("AskHub の対象に無いリポジトリです。対象に加えると、ここから依頼できます")
                            .appFont(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("別のリポジトリへの依頼の案")
        } footer: {
            Text("この epic では作りません。最終 PR を待たずに、そのリポジトリへの依頼として出せます")
        }
        .sheet(item: $draft) { draft in
            NewRequestSheet(draft: draft)
        }
    }

    /// 対象のリポジトリならアプリの名前を添える
    private func repositoryLabel(_ request: Goal.OutsideRequest) -> String {
        guard let repository = store.repository(request.repositoryID) else {
            return request.repositoryFullName
        }
        return "\(repository.appName)（\(request.repositoryFullName)）"
    }
}
