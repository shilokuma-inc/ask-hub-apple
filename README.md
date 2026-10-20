# AskHub

ループ開発（ralph-loop）で人間の判断が必要なものだけを集めて回答する macOS / iOS アプリです。
Discussion の質問や PR の ask を 1 つの一覧にまとめ、アプリで回答すると GitHub に返信され、止まっていたループが再開します。

構想と決定事項は [Discussion #1](https://github.com/shilokuma-inc/ask-hub-apple/discussions/1) を参照してください。

## Environment

- Xcode 26.6
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
| `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION` | アプリのバージョン / ビルド番号。ビルド番号は Upload のときに App Store Connect の最新ビルドを見て Xcode が自動で増やす（`manageAppVersionAndBuildNumber`）ため、手で上げる必要はありません |
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

| ブランチ | Build（ビルド + テスト + SwiftLint） | Archive（IPA / pkg の Export） | Upload（App Store Connect。iOS / macOS） |
|---|:-:|:-:|:-:|
| `main` | ✅ | ✅ | |
| `develop` | ✅ | | ✅ |
| `release/**` | ✅ | | ✅ |
| その他の作業ブランチ | ✅（Unit テストのみ。macOS で実行） | | |
| Pull Request の作成時（opened / reopened / ready_for_review） | ✅ | | |
| Fork からの Pull Request | ✅ | | |

- Upload は Archive → Export を含むため、`develop` / `release/**` では Archive を別途実行しません
- Archive と Upload は iOS（IPA）と macOS（pkg）を別々のジョブで扱い、macOS が失敗しても iOS は止まりません。macOS のアップロードは App Store Connect のアプリに macOS のプラットフォームを追加するまで飛ばします（失敗にはせず、追加の手順を Job Summary に出します）。詳しくは [docs/release.md](docs/release.md) の「macOS 版のアップロード」を参照してください
- `release/**` は Release/Prepare（`.github/workflows/release-prepare.yml`。AskHub の「リリース準備」）が `develop` から作ります。このときの push は `GITHUB_TOKEN` で行うため Build・Upload は push では動かず、Release/Prepare が Upload・スクリーンショット・メタデータを `workflow_dispatch` で起動します。詳しくは [docs/release.md](docs/release.md) の「リリース準備」を参照してください
- Upload は Actions タブから手動でも実行できます（Run workflow）。epic → `develop` の最終 PR をマージする前に TestFlight で実機確認したいときは、Actions → Upload → Run workflow で epic ブランチ（最終 PR の head）を選んで実行します。AskHub アプリのマージ待ちの「TestFlight に上げる」も同じ手動実行（`workflow_dispatch`）を呼びます。ビルド番号は App Store Connect の最新から自動で増えるため、同じバージョンのままビルド番号だけが増えて TestFlight に並びます。App Store Connect には 24 時間あたりのアップロード上限があるため、作業ブランチの push では自動では上げません
- リポジトリ変数（Settings → Secrets and variables → Actions → Variables）に `ENABLE_DELIVERY=false` を設定すると Upload をスキップします（Archive は App Store Connect にアプリが無くても通るため止めません）。何もしなければ従来どおり実行されます
- `ENABLE_MACOS_DELIVERY=false` を設定すると、Upload と Archive の macOS のジョブと、メタデータ・スクリーンショットの macOS のバージョンへの反映をスキップします。何もしなければ macOS のプラットフォームの有無を見て自動で決めます
- ドキュメントだけの変更（`**/*.md`、`docs/**`）では Build を実行しません。Upload（`develop` / `release/**` への push・手動実行）と Archive（`main` への push）は、ドキュメントだけの変更でも実行します
- 作業ブランチへの push では、Simulator の起動に時間がかかるため iOS はビルドの確認だけにし、UI テスト（`AskHubUITests`）を省いた Unit テストを macOS 上で実行します（アドホック署名・App Sandbox 無効）。UI テストは Pull Request の作成時と `main` / `develop` / `release/**` への push で実行します。Fork からの Pull Request は push で実行されないため、更新（synchronize）を含むすべてのイベントで UI テストまで実行します
- Xcode のバージョンは [.github/workflows/_build.yml](.github/workflows/_build.yml) と [.github/workflows/_archive.yml](.github/workflows/_archive.yml) の `xcode-version` で固定しています。Environment の更新時はあわせて変更してください

### 5. PR 本文のスクリーンショット

UI の見た目が変わる変更では、Before / After のスクリーンショットを PR 本文に添付します。

- 画像は GitHub の添付ファイルとしてアップロードします。git の履歴やブランチには含まれず、マージ後も表示され続けます
  - ブラウザで PR を作る場合は、本文の入力欄に画像をドラッグ & ドロップします
  - CLI（エージェントを含む）では `gh` の `--attach`（gh v2.99.0 以上）を使います。本文に Markdown の表と `![Before](./before.png)` の形でローカルのパスを書き、同じファイルを `--attach` で渡すと、gh がその場でアップロード先の URL に書き換えます
  - HTML の `<img src="./before.png">` や `<table>` の中のパスは書き換わりません。表は Markdown で書き、幅をそろえたいときは作成後に `<img width="300">` へ置き換えます（下の例）
- アップロードした画像は削除できません。個人情報やトークンなどが写っていないか確認してから添付してください
- Before / After は表で横に並べ、同一条件（同じ端末・OS・外観モード・データ状態）で撮影します
- 影響する画面が複数ある場合は画面ごとに用意します。新規画面で Before が無い場合は「なし」と書きます

```bash
# body.md の表に ![Before](./before.png) と ![After](./after.png) を書いておく
gh pr create --title "..." --body-file body.md --assignee @me \
  --attach ./before.png --attach ./after.png

# 本文の画像を幅 300 の <img> に置き換える（本文を取得できたときだけ更新する）
body=$(gh pr view <番号> --json body -q .body) &&
  printf '%s\n' "$body" \
  | perl -pe 's{!\[([^\]]*)\]\((https://github\.com/user-attachments/assets/[^)\s]+)\)}{<img src="$2" alt="$1" width="300">}g' \
  | gh pr edit <番号> --body-file -
```

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
├── AppStore/                # App Store のメタデータ（掲載文・言語・アプリの設定）。docs/release.md
├── Tools/                   # App Store Connect への反映のスクリプト（Python）
├── docs/                    # ExportOptions.plist のサンプル・審査の準備・リリース
├── scripts/                 # ralph-loop の setup / start / stop
├── .swiftlint.yml           # SwiftLint 設定
└── .github/
    ├── ISSUE_TEMPLATE/      # Issue テンプレート
    ├── pull_request_template.md
    ├── scripts/             # check-app-store-app.rb / check-app-store-platform.rb（App Store Connect のアプリ・macOS のプラットフォームの有無を確認）
    └── workflows/
        ├── _build.yml       # 共通処理: ビルド + テスト + SwiftLint（workflow_call）
        ├── _archive.yml     # 共通処理: Archive → Export（→ Upload）。iOS / macOS（workflow_call）
        ├── build.yml        # 全ブランチの push / PR の作成時 / Fork からの PR
        ├── archive.yml      # main の push
        ├── upload.yml       # develop / release/** の push・手動実行（workflow_dispatch）
        ├── app-store-metadata.yml         # App Store のメタデータの反映（手動実行）
        └── verify-app-store-metadata.yml  # PR でメタデータを検査
```

- プロジェクトはフォルダ同期グループ（Xcode 16 以降の形式）で管理しているため、ファイルの追加・削除で pbxproj は変わりません
- SwiftLint は Build Tool Plugin として全ターゲットに適用され、CI では `swiftlint lint --strict` としても実行されます。ルールは [.swiftlint.yml](.swiftlint.yml) で管理します
- CI のワークフローは `*.xcodeproj` の名前と同名の共有スキームが存在することを前提にしています

## License

[MIT License](LICENSE)
