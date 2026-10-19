import AskHubKit
import Foundation

/// 「任意判断」「実機確認」のサンプルの Issue（`SampleInboxSource.lowPriorityIssues` が返す）
extension SampleInboxSource {
    /// 実機確認には、目印（`ask-hub:verify`）のあるものと無いものの両方を入れる
    static let issues = [
        InboxIssue(
            id: "I_9",
            kind: .decisionLog,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 9,
            title: "【CHORE】epic/mvp の仮決め一覧",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/9")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-3 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-10 * 60),
            body: """
                チェックを付けたものは承認。変更したいものはコメントで `#<PR番号> は別案 1 で` のように指示。返答のないものは既定値のまま確定する。

                - [x] #12 一覧の並び順 → 採用: 更新の新しい順（別案: 作成の古い順）
                - [x] #13 行の高さ → 採用: 44pt（別案: 52pt） → 変更: 別案 1（52pt）
                - [ ] #14 自動更新の間隔 → 採用: 5 分（別案: 1 分 / 15 分）
                - [ ] #15 空の一覧の文言 → 採用: 「ありません」
                - [ ] 通知の文言は実機で見てから決める
                """
        ),
        InboxIssue(
            id: "I_18",
            kind: .needsVerify,
            repository: "shilokuma-inc/ask-hub-apple",
            number: 18,
            title: "【CHORE】実機確認: PAT の Keychain への保存と macOS の設定画面の見た目",
            url: URL(string: "https://github.com/shilokuma-inc/ask-hub-apple/issues/18")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-5 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-50 * 60),
            body: """
                \(VerifyMarker(pullRequest: 17, epic: "epic/mvp").marker)
                元の PR: #17

                ## 確認手順
                1. macOS 版の設定画面で PAT を入力して保存する
                2. アプリを終了して開き直す

                ## 期待する結果
                - PAT が残っていて、受信箱を取得できる
                - 設定画面の入力欄とボタンが重ならない
                """
        ),
        // 更新の新しい順では実機確認より後ろに来る判断ログ（タブに分けたときの並びの確認用）
        InboxIssue(
            id: "I_77",
            kind: .decisionLog,
            repository: "shilokuma-inc/notti-ios",
            number: 77,
            title: "【CHORE】epic/notification の仮決め一覧",
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/issues/77")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-9 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-70 * 60),
            body: """
                チェックを付けたものは承認。変更したいものはコメントで `#<PR番号> は別案 1 で` のように指示。返答のないものは既定値のまま確定する。

                - [ ] #80 通知の既定の時刻 → 採用: 21 時（別案: 20 時 / 22 時）
                """
        ),
        // 目印（`ask-hub:verify`）が決まる前に起票された実機確認。本文の「元の PR」は自由文なので読まない
        InboxIssue(
            id: "I_52",
            kind: .needsVerify,
            repository: "shilokuma-inc/notti-ios",
            number: 52,
            title: "【CHORE】実機確認: 通知の許可ダイアログと届いた通知の表示",
            url: URL(string: "https://github.com/shilokuma-inc/notti-ios/issues/52")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-16 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-3 * 60 * 60),
            body: """
                元の PR: #41

                ## 確認手順
                1. 実機でアプリを初めて開き、通知を許可する
                2. 通知の時刻まで待つ

                ## 期待する結果
                - 設定した時刻に通知が届き、タップするとアプリが開く
                """
        ),
        // ask-hub-apple と notti-ios は同じ色になるので、行の左の線の色が分かれるよう別の色のリポジトリを足す
        InboxIssue(
            id: "I_31",
            kind: .decisionLog,
            repository: "shilokuma-inc/beat-tap-ios",
            number: 31,
            title: "【CHORE】epic/practice-mode の仮決め一覧",
            url: URL(string: "https://github.com/shilokuma-inc/beat-tap-ios/issues/31")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-2 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-5 * 60 * 60),
            body: """
                チェックを付けたものは承認。変更したいものはコメントで `#<PR番号> は別案 1 で` のように指示。返答のないものは既定値のまま確定する。

                - [ ] #33 練習モードの既定のテンポ → 採用: 80 BPM（別案: 60 BPM / 100 BPM）
                """
        ),
        InboxIssue(
            id: "I_36",
            kind: .needsVerify,
            repository: "shilokuma-inc/beat-tap-ios",
            number: 36,
            title: "【CHORE】実機確認: 練習モードの音とタップのずれ",
            url: URL(string: "https://github.com/shilokuma-inc/beat-tap-ios/issues/36")!,
            author: "mrs1669",
            createdAt: Self.now.addingTimeInterval(-1 * 24 * 60 * 60),
            updatedAt: Self.now.addingTimeInterval(-6 * 60 * 60),
            body: """
                \(VerifyMarker(pullRequest: 35, epic: "epic/practice-mode").marker)
                元の PR: #35

                ## 確認手順
                1. 実機で練習モードを開き、イヤホンで音を聞きながらタップする

                ## 期待する結果
                - 音とタップの判定がずれない
                """
        )
    ]
}
