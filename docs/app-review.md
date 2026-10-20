# App Store 審査の準備

App Store Connect に入力する値と、審査で指摘されやすい点への対応をまとめる（Issue #2）。
プライバシーポリシーの URL は、担当者が App Store Connect に直接入力する（サポート URL は `AppStore/metadata/shared.json` から反映する）。

## 審査で指摘されやすい点と対応

| 論点（ガイドライン） | 対応 |
| --- | --- |
| ログインが必要な機能を審査員が試せない（2.1） | デモモード（`AskHub/DemoMode.swift`）で、トークンなしで全画面を試せる。審査メモに入り方を書く |
| 必要な理由の申告が要る API の申告漏れ（プライバシーマニフェスト） | `AskHub/PrivacyInfo.xcprivacy` で `UserDefaults` の理由 `CA92.1` を申告している。トラッキング・収集するデータは無し |
| 他のアプリやツールが無いと動かない（4.2.3） | GitHub の Discussion・PR・Issue に回答・マージする機能は GitHub のトークンだけで動く。オーケストレーターは任意の追加機能で、無くても「手動で回す」を選べば Claude Code で手動ループを回せる。説明文と審査メモでこの順に書く |
| 最低限の機能（4.2） | 説明文で「開発者向けの GitHub クライアント」であることを先に書く |
| 暗号化の輸出規制 | HTTPS だけなので `ITSAppUsesNonExemptEncryption = false`（`AskHub/Info.plist`）。追加の書類は不要 |
| アカウントの削除（5.1.1(v)） | アプリでアカウントを作らないので対象外。トークンは設定画面の「トークンを削除」で Keychain から消せる |

### 新しい API を使うとき

`UserDefaults` 以外の「必要な理由の申告が要る API」（ファイルのタイムスタンプ・起動からの経過時間・ディスクの空き容量・有効なキーボード）を
アプリや `AskHubKit` で使い始めたら、`PrivacyInfo.xcprivacy` の `NSPrivacyAccessedAPITypes` に理由を足す。
申告が漏れていてもアップロードは通り、審査に出したときやメールで指摘される。

## App Store Connect に入力する値

### App 情報

| 項目 | 値 |
| --- | --- |
| カテゴリ | 開発ツール（Developer Tools）。サブカテゴリは無し |
| 年齢制限 | すべて「なし」で 4+。ただし GitHub 上の第三者が書いた文章を表示するので、「ユーザー生成コンテンツ」を問われたら実態に合わせて答える |
| コンテンツの権利 | 第三者のコンテンツは表示するが、利用者自身のリポジトリのもの |

### App のプライバシー

- 「データを収集しない」を選ぶ
  - 開発者のサーバーは無く、通信先は GitHub の API だけ。トークンと設定は端末（Keychain・UserDefaults）にだけ保存する
  - 分析 SDK・クラッシュ収集 SDK・広告は入れていない（入れたら回答を見直す）

### App Review に関する情報

- **サインインが必要**: オフにする（デモモードで試せるため）。審査員から求められたときだけ、権限を読み取りに絞ったトークンを用意する
- **メモ**（英語で入力する）:

```text
AskHub is a GitHub client for developers who run AI coding loops (Claude Code with the
open-source "ralph-loop" plugin). It collects only the questions that need a human decision
from GitHub Discussions, Pull Requests and Issues, and posts the developer's answers back
to GitHub as comments.

How to try the app without a GitHub account:
1. Launch the app. Each tab shows a "サンプルデータで試す" (Try with sample data) button.
   It is also in Settings (gear icon) > "サンプルデータで試す".
2. The app switches to Demo Mode and shows sample data. A "デモモード" (Demo Mode) banner
   appears at the top. In Demo Mode the app never connects to GitHub; answering,
   merging and sending requests are simulated.
3. Tap "終了" (End) on the banner to leave Demo Mode.

How the app works with real data:
- The user enters a GitHub fine-grained personal access token in Settings. It is stored
  only in the Keychain and sent only to api.github.com.
- Answering questions, merging pull requests and closing issues work with the token alone.
- Optionally, the developer can run an open-source command-line tool on their own Mac
  that watches GitHub and restarts the coding loop after an answer. The app itself never
  launches local processes; without that tool the developer can restart the loop manually.

The app does not collect any data. There is no server operated by the developer.
The UI is in Japanese.
```

### 説明文（日本語）

プロモーションテキスト・説明・キーワードは `AppStore/metadata/ja.json` に同じ文言を置き、ワークフローで App Store Connect に反映する（[docs/release.md](release.md) の「App Store のメタデータ」）。
ここを書き換えたら `ja.json` も合わせる。サブタイトルは反映の対象外なので、App Store Connect に直接入力する。

- **サブタイトル**（30 文字以内）: `AI 開発ループの質問に答える GitHub クライアント`
- **プロモーションテキスト**: `ループが止まって待っている判断だけを、iPhone と Mac で 1 つの一覧に。`
- **説明**:

```text
AskHub は、Claude Code などの AI に実装を任せて回す開発ループのための GitHub クライアントです。
ループが人間の判断を必要として止まったときの質問だけを、GitHub の Discussion・Pull Request・Issue から集めて 1 つの一覧に出します。

■ できること
・要対応: 未回答の質問とマージ待ちの PR を一覧にし、その場で回答・マージ
・任意判断: ループが仮に決めたことの一覧を確認し、必要なら指示を出す
・実機確認: 実機での確認が必要な Issue を確認して閉じる
・依頼: 新しい機能の依頼を Issue として出す
・ステータス: 動いているループの状態を確認する

■ 使い方
GitHub の Fine-grained personal access token を設定画面に入力します。トークンは端末の Keychain にだけ保存し、GitHub の API にだけ送ります。
トークンが無くても「サンプルデータで試す」で画面と操作を試せます。

■ ループの自動再開（任意）
回答したらループを自動で再開させたいときは、Mac に常駐するオープンソースのツール（AskHub のリポジトリに同梱）を使います。
使わない場合も、回答後に手元の Claude Code でループを手動で再開できます。

■ プライバシー
開発者のサーバーはありません。データを収集しません。
```

- **キーワード**（100 バイト以内・カンマ区切り）: `GitHub,Claude,AI,開発,ループ,PR,レビュー,Discussion,Issue,エージェント`

## まだ残っていること

- プライバシーポリシーの URL（担当者が入力する）。サポート URL は `AppStore/metadata/shared.json` のリポジトリの URL を反映する
- スクリーンショット（デモモードで撮る）
- 認証を Fine-grained PAT から GitHub の OAuth のデバイスフローに切り替える（審査の必須ではない。一般公開するなら望ましい）
