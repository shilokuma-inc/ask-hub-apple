import SwiftUI

/// 設定の「送った操作」の節。この端末が送った人の意図のうち、新しいものだけを出し、残りは「すべて見る」から開く画面に並べる
struct SentIntentsSection: View {
    /// 設定に出す件数。1 行が長いので、多く並べると下の節（Siri とショートカット・このアプリについて）が遠くなる
    static let visibleLimit = 5

    /// 新しい順
    let intents: [SentIntentStatus]

    var body: some View {
        if !intents.isEmpty {
            Section("送った操作") {
                ForEach(intents.prefix(Self.visibleLimit)) { intent in
                    SentIntentRow(intent: intent)
                }
                if intents.count > Self.visibleLimit {
                    NavigationLink {
                        SentIntentListView()
                    } label: {
                        LabeledContent("すべて見る", value: "\(intents.count) 件")
                    }
                }
            }
        }
    }
}

/// この端末が送った操作をすべて、新しい順に並べる（読んでいる新しいものだけ）
struct SentIntentListView: View {
    @Environment(ClientStore.self) private var store

    var body: some View {
        let intents = store.snapshot?.sentIntents ?? []
        Form {
            Section {
                ForEach(intents) { intent in
                    SentIntentRow(intent: intent)
                }
            }
        }
        .formStyle(.grouped)
        .pastelBackground()
        .navigationTitle("送った操作")
    }
}

/// 送った操作の 1 行。何を送ったかと、司令塔の処理の結果
struct SentIntentRow: View {
    let intent: SentIntentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(intent.title)
            Text(stateLabel).appFont(.caption).foregroundStyle(isRejected ? .red : .secondary)
        }
    }

    private var stateLabel: String {
        switch intent.state {
        case .waiting:
            "司令塔が受け取るのを待っています"

        case .accepted(let date):
            "受け付けました · \(date.formatted(date: .abbreviated, time: .shortened))"

        case let .rejected(_, reason):
            "受け付けませんでした: \(reason)"
        }
    }

    private var isRejected: Bool {
        if case .rejected = intent.state {
            return true
        }
        return false
    }
}
