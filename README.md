# AskHub

ループ開発（ralph-loop）で人間の判断が必要なものだけを集めて回答する macOS / iOS アプリです。
Discussion の質問や PR の ask を 1 つの一覧にまとめ、アプリで回答すると GitHub に返信され、止まっていたループが再開します。

構想と決定事項は [Discussion #1](https://github.com/shilokuma-inc/ask-hub-apple/discussions/1) を参照してください。

## Environment

- Xcode 26.3
- iOS 17.0 以上 / macOS 14.0 以上（SwiftUI マルチプラットフォーム）
- Swift 6（Swift 6 言語モード / Strict Concurrency）
- SwiftUI / Swift Testing / XCTest（UI テスト）
- SwiftLint 0.65.1（Build Tool Plugin）

## Status

<div style="margin:0px;padding:0px;">
  <table width="98%" style="border-collapse: collapse;border:2px double #000080;text-align:center;margin:auto;">
    <tbody>
      <tr>
        <td style="border:2px double #000080;">branch \ workflow</td>
        <td style="border:2px double #000080;">Build</td>
        <td style="border:2px double #000080;">Archive</td>
        <td style="border:2px double #000080;">Upload</td>
      </tr>
      <tr>
        <td style="border:2px double #000080;text-align:left;">main</td>
        <!-- main ブランチは初回リリースで作成する。作成までは実行履歴が無くバッジが「no status」になるため、
             作成後に次のバッジを戻す:
          build.yml/badge.svg?branch=main&event=push（Build）、archive.yml/badge.svg?branch=main（Archive） -->
        <td style="border:2px double #000080;text-align:center;">
          未作成
        </td>
        <td style="border:2px double #000080;text-align:center;">
          未作成
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
      </tr>
      <tr>
        <td style="border:2px double #000080;text-align:left;">develop</td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-inc/ask-hub-apple/actions/workflows/build.yml?query=branch%3Adevelop+event%3Apush">
            <img src="https://github.com/shilokuma-inc/ask-hub-apple/actions/workflows/build.yml/badge.svg?branch=develop&event=push" alt="Build">
          </a>
        </td>
        <td style="border:2px double #000080;text-align:center;">
        </td>
        <td style="border:2px double #000080;text-align:center;">
          <a href="https://github.com/shilokuma-inc/ask-hub-apple/actions/workflows/upload.yml?query=branch%3Adevelop">
            <img src="https://github.com/shilokuma-inc/ask-hub-apple/actions/workflows/upload.yml/badge.svg?branch=develop" alt="Upload">
          </a>
        </td>
      </tr>
    </tbody>
  </table>
</div>

## セットアップ

### 1. 署名情報を設定する

署名情報やバージョンは pbxproj ではなく [Configs/Project.xcconfig](Configs/Project.xcconfig) に集約しています。
値を変更するときはここを書き換えてください。

| 設定 | 内容 |
|---|---|
| `DEVELOPMENT_TEAM` | Apple Developer Program の Team ID |
| `APP_BUNDLE_IDENTIFIER` | アプリ本体の Bundle Identifier。テストターゲットは `.Tests` / `.UITests` を付けて自動で派生します |
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | アプリのバージョン / ビルド番号 |
| `IPHONEOS_DEPLOYMENT_TARGET` / `MACOSX_DEPLOYMENT_TARGET` | 最低サポート OS |

### 2. GitHub Secrets を設定する

Archive / Upload ワークフローは App Store Connect API Key で認証します。
リポジトリの Settings → Secrets and variables → Actions に以下を登録してください。

| Secret | 内容 |
|---|---|
| `EXPORT_OPTIONS` | `ExportOptions.plist` の内容。[docs/ExportOptions.sample.plist](docs/ExportOptions.sample.plist) の `teamID` を書き換えて、ファイルの中身をそのまま登録します |
| `APPLE_API_KEY_BASE64` | App Store Connect の API Key（`AuthKey_XXXXXXXXXX.p8`）を `base64 -i AuthKey_XXXXXXXXXX.p8` でエンコードした文字列 |
| `APPLE_API_KEY_ID` | API Key の Key ID |
| `APPLE_API_ISSUER_ID` | API Key の Issuer ID |

API Key は App Store Connect の「ユーザとアクセス → 統合 → App Store Connect API」で、App Manager 以上の権限で発行します。
### 3. App Store Connect にアプリを作成する

Bundle ID・証明書・プロビジョニングプロファイルは、Export のときに API Key で自動的に作成されます（`-allowProvisioningUpdates`）。
App Store Connect でのアプリ作成だけは API で行えないため、Web 画面で行います。

アプリを作らずに `develop` へ push しても問題ありません。Upload ワークフローがアップロードの前にアプリの有無を確認し（[.github/scripts/check-app-store-app.rb](.github/scripts/check-app-store-app.rb)）、アプリが無ければ「新規アプリ」画面に入力する値（名前・バンドル ID・SKU など）を Job Summary に表示して止まります。表示された値でアプリを作成してから、ワークフローを再実行してください。

SKU は Bundle ID と同じ値にします。SKU はユーザーには見えない社内用の ID で、後から変更できないため、迷わないようにルールを固定しています。

### 4. ブランチ運用と CI

| ブランチ | Build（ビルド + テスト + SwiftLint） | Archive（IPA Export） | Upload（App Store Connect） |
|---|:-:|:-:|:-:|
| `main` | ✅ | ✅ | |
| `develop` | ✅ | | ✅ |
| `release/**` | ✅ | | ✅ |
| その他の作業ブランチ | ✅（Unit テストのみ。macOS で実行） | | |
| Pull Request の作成時（opened / reopened / ready_for_review） | ✅ | | |
| Fork からの Pull Request | ✅ | | |
| `assets/**`（スクリーンショット置き場） | | | |

- Upload は Archive → IPA Export を含むため、`develop` / `release/**` では Archive を別途実行しません
- `assets/**` はアプリのコードを含まないため、どのワークフローも実行しません
- ドキュメントだけの変更（`**/*.md`、`docs/**`）では Build を実行しません。Upload（`develop` / `release/**` への push）と Archive（`main` への push）は、ドキュメントだけの変更でも実行します
- 作業ブランチへの push では、Simulator の起動に時間がかかるため iOS はビルドの確認だけにし、UI テスト（`AskHubUITests`）を省いた Unit テストを macOS 上で実行します（アドホック署名・App Sandbox 無効）。UI テストは Pull Request の作成時と `main` / `develop` / `release/**` への push で実行します。Fork からの Pull Request は push で実行されないため、更新（synchronize）を含むすべてのイベントで UI テストまで実行します
- Xcode のバージョンは [.github/workflows/_build.yml](.github/workflows/_build.yml) と [.github/workflows/_archive.yml](.github/workflows/_archive.yml) の `xcode-version` で固定しています。Environment の更新時はあわせて変更してください

### 5. PR 本文のスクリーンショット

UI の見た目が変わる変更では、Before / After のスクリーンショットを PR 本文に添付します。

- 画像は PR の diff を汚さないよう **`assets/issue-<Issue番号>` ブランチ**に置き、PR 本文からは raw URL で参照します
  - 例: `https://raw.githubusercontent.com/<owner>/<repo>/assets/issue-12/12/before.png`
  - このブランチは [.github/workflows/cleanup-assets-branch.yml](.github/workflows/cleanup-assets-branch.yml) が PR のマージ時に自動削除します。ブランチ名がこの規約から外れると削除されないので注意してください
- Before / After は表で横に並べ、同一条件（同じ端末・OS・外観モード・データ状態）で撮影します
- 影響する画面が複数ある場合は画面ごとに用意します。新規画面で Before が無い場合は「なし」と書きます

### 6. アプリアイコンを差し替える

アプリアイコンは Icon Composer のバンドル [AskHub/AppIcon.icon](AskHub/AppIcon.icon) で管理しています（iOS / macOS 共通。ライト・ダーク・ティントの外観と旧 OS 向けのフォールバックは Xcode がビルド時に生成します）。

- 元の絵は `AskHub/AppIcon.icon/Assets/` の SVG（吹き出し `bubble.svg` と❓ `question.svg`）です。テキストなので直接編集もできます
- Icon Composer（Xcode 26 以降に同梱）で `AskHub/AppIcon.icon` を開き、レイヤーの画像・背景色・ガラスの質感を編集して保存します。背景色やレイヤーの順は `icon.json` に保存されます
- `AskHub/` はフォルダ同期グループなので、`.icon` を置き換えるだけでターゲットに入ります。pbxproj と xcconfig の変更は不要です（`ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` のまま拾われます）
- 差し替えたら iOS Simulator のホーム画面と macOS の Dock で見た目を確かめ、PR にスクリーンショットを載せます

## 構成

```
.
├── Configs/                 # xcconfig（署名情報・バージョン・Deployment Target）
├── AskHub/          # アプリ本体（SwiftUI）
├── AskHubTests/     # Unit テスト（Swift Testing）
├── AskHubUITests/   # UI テスト（XCTest）
├── AskHub.xcodeproj # 共有スキーム AskHub を含む
├── docs/                    # ExportOptions.plist のサンプル
├── scripts/                 # ralph-loop の setup / start / stop
├── .swiftlint.yml           # SwiftLint 設定
└── .github/
    ├── ISSUE_TEMPLATE/      # Issue テンプレート
    ├── pull_request_template.md
    ├── scripts/             # check-app-store-app.rb（App Store Connect のアプリの有無を確認）
    └── workflows/
        ├── _build.yml       # 共通処理: ビルド + テスト + SwiftLint（workflow_call）
        ├── _archive.yml     # 共通処理: Archive → Export（→ Upload）（workflow_call）
        ├── build.yml        # 全ブランチの push / PR の作成時 / Fork からの PR
        ├── archive.yml      # main の push
        ├── upload.yml       # develop / release/** の push
        └── cleanup-assets-branch.yml # PR マージ時に assets/issue-<番号> ブランチを削除
```

- プロジェクトはフォルダ同期グループ（Xcode 16 以降の形式）で管理しているため、ファイルの追加・削除で pbxproj は変わりません
- SwiftLint は Build Tool Plugin として全ターゲットに適用され、CI では `swiftlint lint --strict` としても実行されます。ルールは [.swiftlint.yml](.swiftlint.yml) で管理します
- CI のワークフローは `*.xcodeproj` の名前と同名の共有スキームが存在することを前提にしています

## License

[MIT License](LICENSE)
