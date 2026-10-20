# リリース

App Store へのリリースの流れと、そのためのワークフロー・人がすること・必要な Secrets をまとめる（Discussion #605）。
App Store Connect に出す値と審査で指摘されやすい点は [docs/app-review.md](app-review.md) を参照する。

ワークフローは、テンプレート（[shilokuma-inc/template-app-ios](https://github.com/shilokuma-inc/template-app-ios)）と見比べやすいよう、なるべく同じ形で置いている。

## App Store のメタデータ

App Store の説明文・キーワード・プロモーションテキスト・最新情報・URL を、リポジトリの JSON から App Store Connect に反映する。

### 仕組み

| ファイル | 役割 |
| --- | --- |
| `AppStore/app.json` | プロジェクト・Scheme などアプリごとの設定。Bundle ID は `Configs/Project.xcconfig` の `APP_BUNDLE_IDENTIFIER` から読む |
| `AppStore/languages.json` | 載せる言語の一覧。今は `ja` だけ（アプリの画面が日本語だけのため） |
| `AppStore/metadata/<言語>.json` | 言語ごとの `description`・`keywords`（配列）・`promotionalText`・`whatsNew` |
| `AppStore/metadata/shared.json` | 言語によらない `supportUrl`（必須）・`marketingUrl`（任意） |
| `Tools/upload_metadata.py` | JSON を検査し（`--check`）、App Store Connect に反映する（`--dry-run` で差分だけ） |
| `Tools/app_store_config.py` / `Tools/app_store_connect.py` | `AppStore/*.json` の読み取りと、App Store Connect API のクライアント |
| `Tools/app_store_platform.py` | 反映先のプラットフォーム（iOS / macOS）の表示名と、反映先のバージョンが無いときの判定 |
| `.github/workflows/verify-app-store-metadata.yml`（Verify/App Store metadata） | PR で `AppStore/`・`Tools/` などが変わると、欠損・文字数の上限・Bundle ID を検査する |
| `.github/workflows/app-store-metadata.yml`（Metadata/App Store） | 手動実行で App Store Connect に反映する。既定は dry-run |

- 上限は `description` 4000 字・`keywords` カンマ込みで 100 字・`promotionalText` 170 字・`whatsNew` 4000 字。超えると PR の検査で落ちる
- 反映するのは「編集できる状態」（`PREPARE_FOR_SUBMISSION` など）のバージョンだけ。審査中・配信済みのバージョンには触らない
- iOS と macOS のバージョンの両方に、同じ JSON を反映する（App Store Connect のバージョンはプラットフォームごとに別にあり、言語ごとの掲載文もそれぞれにある）。
  `Tools/upload_metadata.py` は `--platform`（`IOS` / `MAC_OS`。既定は `IOS`）で反映先を選び、ワークフローはプラットフォームごとに 1 回ずつ実行する
- macOS のバージョンが無い（macOS のプラットフォームを追加していない・指定したバージョン番号の macOS のバージョンが無い・配信を終えたバージョンしか無い）ときは、macOS を飛ばして iOS だけに反映し、Job Summary に知らせる（`--missing-version skip`）。
  macOS のバージョンが審査中などで編集できない・候補が複数あるときは、iOS と同じく止まる（iOS の反映は先に終わっている）
- リポジトリ変数 `ENABLE_MACOS_DELIVERY` が `false` なら、macOS には反映しない（「macOS 版のアップロード」と同じ変数）
- JSON に書いていない項目（例: 省略した `promotionalText`・`marketingUrl`）は、App Store Connect 側の値をそのまま残す
- `whatsNew` は `{"version": "1.1.0", "text": "…"}` の形で書き、`version` が反映先のバージョンと一致するときだけ書き込む。
  そのプラットフォームの最初のバージョンには最新情報の欄が無いので、`whatsNew` が書いてあっても送らない（「最新情報の確定」の「初めてのリリースの最新情報」）。
  リリースのたびの `whatsNew` は Release/Notes が release ブランチで書く
- 掲載文の元は [docs/app-review.md](app-review.md) の「説明文（日本語）」。審査で指摘されやすい点（4.2・4.2.3）への対応を崩さないよう、書き換えるときは両方を見る

手元で検査する（App Store Connect にはつながない）:

```bash
python3 Tools/upload_metadata.py --check
python3 Tools/app_store_config.py bundle-id
```

### 人がすること

1. App Store Connect でアプリと、反映先のバージョン（「準備中」の状態）を作っておく
2. Actions → **Metadata/App Store** → Run workflow で、反映したいブランチを選んで実行する
   - まず `dry_run` をオンのまま実行し、Job Summary の差分（App Store Connect の現在値 → JSON の値）を確かめる
   - よければ `dry_run` をオフにして再実行する
   - 編集できるバージョンが複数あるときは `app_version` で選ぶ。App Store Connect のバージョンに言語（`ja`）が無いときは `missing_locales` を `create` にする
   - Job Summary は iOS と macOS に分かれる。macOS を飛ばしたときは「macOS には反映していません」と、飛ばした理由と、理由に合わせた人がすることが出る
     （プラットフォームが無いなら「macOS 版のアップロード」の「人がすること」の 1 で追加する、配信を終えたバージョンしか無い・指定した番号が無いなら iOS と同じバージョン番号の macOS のバージョンを作る）。
     用意してから再実行する
3. サブタイトル・プライバシーポリシーの URL・カテゴリ・年齢制限は、この仕組みでは反映しない（App 情報の項目のため）。App Store Connect の画面で入力する（値は [docs/app-review.md](app-review.md)）

`workflow_dispatch` はデフォルトブランチ（`develop`）にファイルがあるときしか起動できない。`develop` に入るまでは実行できない。

### Secrets / vars

| 名前 | 種類 | 内容 |
| --- | --- | --- |
| `APPLE_API_KEY_BASE64` | Secret | App Store Connect API Key（`.p8`）を base64 にしたもの。Upload と同じ |
| `APPLE_API_KEY_ID` | Secret | API Key の Key ID |
| `APPLE_API_ISSUER_ID` | Secret | API Key の Issuer ID |
| `ENABLE_DELIVERY` | vars（任意） | `false` にすると Metadata/App Store を実行しない（Upload と同じ）。未設定なら実行する |
| `ENABLE_MACOS_DELIVERY` | vars（任意） | `false` にすると macOS のバージョンには反映しない（iOS だけ）。未設定なら、macOS のバージョンの有無を見て自動で決める |

API Key には App Manager 以上の権限が要る。Verify/App Store metadata は Secrets を使わない（Fork からの PR でも動く）。

## macOS 版のアップロード

`develop` / `release/**` への push と手動実行で、Upload（`.github/workflows/upload.yml`）は iOS と macOS のビルドを App Store Connect に上げる（Discussion #605 の Q8）。

### 仕組み

| ジョブ | すること |
| --- | --- |
| `upload`（iOS） | 今までどおり `-sdk iphoneos` でアーカイブし、IPA を Export・アップロードする |
| `upload-macos`（macOS） | App Store Connect のアプリに macOS のプラットフォームがあるかを確かめ（`.github/scripts/check-app-store-platform.rb`。読み取りだけ）、あれば `generic/platform=macOS` でアーカイブし、pkg を Export・アップロードする |

- 2 つのジョブは別々に動く。macOS が失敗しても iOS のアップロードは止まらない（run 全体の結果は失敗になる）
- macOS のプラットフォームが無いときは、追加の手順を Job Summary に出して macOS のアーカイブを飛ばす（失敗にはしない）。確認は ubuntu のランナーで行い、macOS のランナーは使わない
- `EXPORT_OPTIONS` は iOS と同じものを使う（`method=app-store-connect`）。macOS では pkg が出る。ビルド番号は iOS と同じく Xcode が App Store Connect の最新から増やす（`manageAppVersionAndBuildNumber`。iOS と macOS で別々に数える）
- macOS はアドホック署名でアーカイブし、Export で配布用に署名し直す（署名なしでアーカイブすると App Sandbox のエンタイトルメントが埋め込まれない）
- Mac App Store にはカテゴリ（`LSApplicationCategoryType`）が要るので、`AskHub/Info.plist` に `public.app-category.developer-tools`（開発ツール。[docs/app-review.md](app-review.md) のカテゴリと同じ）を書いている
- Archive（`main` への push）も、iOS と macOS の両方を Export まで確かめる（アップロードはしない）
- 実行中の macOS のランナーは、iOS と macOS で 1 回の Upload につき 2 台。org 全体で同時に 5 台までなので、続けて push すると待たされることがある

### 人がすること

1. [App Store Connect](https://appstoreconnect.apple.com/apps) でアプリを開き、「プラットフォームを追加」（サイドバーのプラットフォームの横の「＋」）から macOS を追加する。
   追加すると macOS のバージョン（提出準備中）ができ、次の Upload から macOS のビルドも上がる（それまでは Job Summary に「macOS のアップロードを飛ばしました」と出る）
2. 追加した後、Actions → **Upload** → Run workflow で `develop`（または release ブランチ）を選んで実行し、`upload-macos / archive` が成功して TestFlight（macOS）にビルドが並ぶのを確かめる
3. macOS の審査への提出・輸出コンプライアンスの回答は、iOS と同じく人が App Store Connect で行う

### vars

| 名前 | 種類 | 内容 |
| --- | --- | --- |
| `ENABLE_DELIVERY` | vars（任意） | `false` にすると Upload の iOS と macOS の両方を実行しない。未設定なら実行する |
| `ENABLE_MACOS_DELIVERY` | vars（任意） | `false` にすると Upload と Archive の macOS のジョブを実行せず、メタデータ・スクリーンショットも macOS のバージョンには反映しない（macOS の署名やアップロードがうまくいかない間、毎回の失敗を止めたいとき）。未設定なら、macOS のプラットフォームの有無を見て自動で決める |

新しい Secret は要らない（`APPLE_API_KEY_BASE64`・`APPLE_API_KEY_ID`・`APPLE_API_ISSUER_ID`・`EXPORT_OPTIONS` は iOS と同じ）。

## App Store のスクリーンショット

App Store のスクリーンショットを、アプリの撮影モードで撮り、App Store Connect に反映する。iOS（iPhone・iPad）と Mac（`APP_DESKTOP`）を撮る。

### 仕組み

| ファイル | 役割 |
| --- | --- |
| `AskHub/ScreenshotDemo.swift` | 撮影モード。起動引数で、デモモードのサンプルデータのまま指定の画面（タブ）を開く |
| `AppStore/screenshots.json` | 撮る画面（`scenes`。この順が App Store の並び順）と表示サイズ（`displayTypes`） |
| `AppStore/app.json` | 撮影でビルドするプロジェクト・Scheme・構成（Release）と、撮影モードのファイル（`screenshotDemoSource`） |
| `Tools/capture_screenshots.sh` | 1 つの表示サイズについて、Simulator を作ってビルドし、言語 × 画面ぶん撮る。撮り終えたら Simulator を消す。Mac の表示サイズは `capture_mac_screenshots.sh` に切り替える |
| `Tools/capture_mac_screenshots.sh` / `AskHubTests/MacScreenshotCaptureTests.swift` | Mac の表示サイズを、macOS のユニットテストで撮る（下の「Mac の撮影」） |
| `Tools/derive_screenshots.py` | `deriveFrom` を書いた表示サイズを、撮った表示サイズから縮めて作る（Pillow が要る） |
| `Tools/verify_screenshots.py` | 寸法・アルファ・枚数が App Store Connect に通る形か確かめる |
| `Tools/remove_alpha.swift` | Simulator・Mac の撮影の画像（RGBA）をアルファの無い PNG に描き直す（撮影スクリプトが使う） |
| `Tools/upload_screenshots.py` | 言語ごとに、その表示サイズのスクリーンショットのセットを入れ直す |
| `.github/workflows/app-store-screenshots.yml`（Screenshots/App Store） | 手動実行で撮って反映する |
| `.github/workflows/verify-app-store-metadata.yml`（Verify/App Store metadata） | PR で、`scenes` が撮影モードの `Scene` にあるか・枚数の上限（10）・表示サイズの設定を検査する |

表示サイズ:

| 表示サイズ | 撮り方 | 寸法 |
| --- | --- | --- |
| `APP_IPHONE_67`（iPhone 6.9 inch） | iPhone 17 Pro Max（無ければ 16 Pro Max）の Simulator で撮る | 1320x2868 |
| `APP_IPHONE_61`（iPhone 6.3 inch） | 6.9 inch を縮めて作る（ubuntu で動く） | 1206x2622 |
| `APP_IPAD_PRO_3GEN_129`（iPad 13 inch） | iPad Pro 13-inch（M5 / M4）の Simulator で撮る | 2064x2752 |
| `APP_DESKTOP`（Mac） | macOS のユニットテストで撮る（下の「Mac の撮影」。`macos-latest` で動く） | 2880x1800（ほかに 2560x1600・1440x900・1280x800 も受け付ける） |

表示サイズの `platform`（`IOS` / `MAC_OS`。省略すると `IOS`）が反映先のバージョンのプラットフォームになる。`APP_DESKTOP` は `MAC_OS` で、macOS のバージョンに反映する。

- `Tools/app_store_config.py display-types` は、撮る方法がある表示サイズ（`devices` を書いた iOS の表示サイズ・Mac の表示サイズ・`deriveFrom` で縮めて作る表示サイズ）を `capture` / `derive` / `upload` に入れ、
  残り（`devices` の無い iOS の表示サイズ）は理由を付けて `skipped` に入れる。`capture` の各項目には撮り方の `method`（`simulator` / `macos-unit-test`）、`upload` の各項目には反映先の `platform` が付く
- `Tools/upload_screenshots.py` は表示サイズの `platform` のバージョンに反映する（`--platform` を渡すと、表示サイズと合うかを確かめる）。
  macOS の表示サイズはワークフローが `--missing-version skip` を付けるので、macOS のバージョンが無いときは飛ばして iOS の表示サイズだけを反映する
- `Tools/verify_screenshots.py --display-type APP_DESKTOP` で、Mac の寸法（16:10 の 4 つ）として検査できる
- `Tools/capture_screenshots.sh` に Mac の表示サイズを渡すと、`Tools/capture_mac_screenshots.sh` に切り替わる

テンプレートにある iPhone Duo（`APP_IPHONE_DUO`）は、GitHub のホストランナーでは撮れない（`xcode-27` のランナーと iOS 27.1 が要る）ので載せていない。

### 撮影モード

撮影スクリプトは、画面ごと・言語ごとにアプリを起動し直し、次の起動引数を渡す:

```text
-screenshot-demo -screenshot-scene <scene> -AppleLanguages (<言語>) -AppleLocale <ロケール>
```

- `-screenshot-demo` だけでサンプルデータ（デモモードと同じ `SampleInbox` など）になり、GitHub にもトークンにもつながない。
  UserDefaults のデモモードの設定（`AskHubDemoMode`）は読み書きせず、デモモードの帯も出さない
- `-screenshot-scene` には `ScreenshotDemo.Scene` の rawValue（今は `action` / `request` / `decisions` / `status` / `verification`）を渡す。
  知らない値・値なしは「要対応」タブになる
- 撮影は Release でビルドするので、撮影モードは `#if DEBUG` にしていない

### 画面（scene）の足し方

1. `AskHub/ScreenshotDemo.swift` の `enum Scene: String` に `case` を足し、`tab` で開くタブを返す。
   `Tools/app_store_config.py` が `enum Scene: String {` から最初の `}` までの `case` を正規表現で読むので、`Scene` の中に `case` 以外の宣言を書かない（準拠やプロパティは extension に書く）
2. `AppStore/screenshots.json` の `scenes` に `{ "file": "06_xxx", "scene": "<rawValue>" }` を足す（`file` の番号の順が App Store の並び順。1 表示サイズにつき 10 枚まで）
3. 手元で検査する: `python3 Tools/app_store_config.py scenes`（`Scene` に無い名前なら止まる）

### 手元で撮る

```bash
SIMULATOR_NAME=AskHub-Screenshot-mine SKIP_PACKAGE_PLUGIN_VALIDATION=1 Tools/capture_screenshots.sh APP_IPHONE_67 ja
```

- `build/screenshots/<表示サイズ>/<言語>/01_action.png …` に保存し、最後に `verify_screenshots.py` で寸法とアルファを確かめる。
  Simulator はスクリプトが作って、終わったら消す（名前は `SIMULATOR_NAME`。既定は `AskHub-Screenshot-<表示サイズ>`）。DerivedData は既定でリポジトリの外（`$TMPDIR`）に置く
- macOS の `/bin/bash`（3.2）で動く。`xcode-select` が Command Line Tools を指している Mac では `DEVELOPER_DIR` を Xcode.app に向ける
- 6.3 inch は撮らずに、`python3 Tools/derive_screenshots.py --display-type APP_IPHONE_61 --screenshots-dir build/screenshots` で作る（Pillow が要る）

### Mac の撮影

macOS には Simulator が無く、GitHub のホストランナー（`macos-latest`）には画面収録・アクセシビリティの許可が無いので、
アプリを起動して画面を撮る方法（macOS の UI テストの `screenshot()`・`screencapture`）は使えないことがある。
そこで、macOS のユニットテスト（`AskHubTests/MacScreenshotCaptureTests`）の中で、撮影モードと同じ画面
（`ContentView` をサンプルデータで、`ScreenshotDemo.Scene` のタブを開いた状態）をウィンドウに出し、
`cacheDisplay(in:to:)` でタイトルバー（タブとツールバー）ごと PNG にする。これなら画面収録の許可は要らない。

- 寸法は `screenshots.json` の `sizes` の先頭（2880x1800）。1440x900 ポイントのウィンドウを 2 倍で描く。外観はライト
- 撮る画面・言語・寸法・出力先は `capture_mac_screenshots.sh` が JSON に書き、`TEST_RUNNER_ASKHUB_SCREENSHOT_PLAN` でテストに渡す（`xcodebuild` は `TEST_RUNNER_` を外した名前でテストに渡す）。
  この環境変数が無いとテストは飛ばされるので、Build（`build.yml`）の Unit テストでは撮らない
- テストは `@testable import` でアプリの View を使うので Debug でビルドする（iOS の撮影は Release）。サンプルデータは同じ
- 言語はロケール（`languages.json` の `appleLocale`）だけを渡す。アプリの文言は日本語だけなので、言語を足すときは文言の切り替えも見直す
- アプリそのものを起動するわけではないので、`-screenshot-demo` / `-screenshot-scene` の起動引数は使わない（`ScreenshotDemo.Scene` と `tab` は同じものを使う）。
  画面の中身は同じだが、メニューバー・Dock は写らない
- 撮った後は iOS と同じく `remove_alpha.swift` でアルファを落とし、`verify_screenshots.py` で寸法と枚数を確かめる
- ランナーは iOS と同じ `capture` の列に並ぶ（`max-parallel: 1`）。Mac の撮影のために macOS ランナーの同時実行は増えない

手元で撮る:

```bash
SKIP_PACKAGE_PLUGIN_VALIDATION=1 Tools/capture_screenshots.sh APP_DESKTOP ja
```

`build/screenshots/APP_DESKTOP/ja/01_action.png …` に保存する。手元の Mac に画面収録の許可が無くても撮れる。
「Mac Development」の署名用証明書が無くても撮れるよう、アドホック署名・App Sandbox なしでテストを流す。

### 人がすること

1. App Store Connect に、反映先のバージョン（「準備中」の状態）を作っておく。Mac にも載せるときは macOS のバージョンも要る（「macOS 版のアップロード」の「人がすること」）
2. Actions → **Screenshots/App Store** → Run workflow で、`release/**` のブランチを選んで実行する
   - 撮るのはリリースのときだけ（`release/**` 以外では止まる）。撮影の仕組みだけを確かめるときは `allow_non_release` をオンにする（反映はしない）
   - `upload` を外すと撮るだけ。撮れた画像は run の artifact（`screenshots-<表示サイズ>`）から取れる
   - `display_types`・`languages` で一部だけ撮り直せる。6.3 inch だけを指定しても、元の 6.9 inch を撮ってから縮める
3. 反映すると、その言語・表示サイズの既存のスクリーンショットは消えて入れ替わる（編集できる状態のバージョンだけ。審査中・配信済みには触らない）

macOS ランナーの枠を開発のビルドと取り合わないよう、撮影は 1 本ずつ（`max-parallel: 1`、ワークフロー全体で 1 つ）にしている。

Secrets / vars は「App Store のメタデータ」と同じ（`APPLE_API_KEY_BASE64`・`APPLE_API_KEY_ID`・`APPLE_API_ISSUER_ID`、任意の `ENABLE_DELIVERY`）。
`ENABLE_DELIVERY=false` のときは撮るだけで反映しない。`ENABLE_MACOS_DELIVERY=false` のときは、Mac の表示サイズを macOS のバージョンに反映しない（撮影はする。撮らないときは `display_types` で Mac を外す）。

## App Store Connect のバージョンとビルド

リリース準備（`release-prepare.yml`）と定期実行（`release-sync.yml`）は、App Store Connect のバージョンの用意・ビルドの紐付け・配信の検知を
`Tools/release_app_store.py` で行う（Discussion #605 の Q4・Q7）。審査への提出と輸出コンプライアンスの回答は人が行う。

### 使い方

```bash
python3 Tools/release_app_store.py prepare --version 1.1.0       # バージョンを用意する（無ければ作る）
python3 Tools/release_app_store.py attach-build --version 1.1.0  # 処理が終わった最新のビルドを紐付ける
python3 Tools/release_app_store.py status --version 1.1.0        # 状態を見て、配信済みかを判定する
```

- 対象は `--platforms`（既定 `IOS,MAC_OS`）。`--dry-run` を付けると読むだけで何も書き換えない
- 認証は Metadata/App Store と同じ（`APP_STORE_CONNECT_KEY_ID`・`APP_STORE_CONNECT_ISSUER_ID`・`APP_STORE_CONNECT_PRIVATE_KEY_PATH`）。Bundle ID は `Configs/Project.xcconfig` から読む
- 結果は JSON で標準出力に出る（人に向けた説明は標準エラー）。終了コードは 0 = 成功・1 = 失敗（`error` に理由）・2 = 引数の誤り（バージョンの形の誤りを含む。App Store Connect は呼ばない）
- どの失敗でも（API の 4xx / 5xx・通信の失敗やタイムアウト・JSON でない応答・`.p8` が無い・引数の誤り）、標準出力には `ok: false` と `error` を持つ JSON が 1 つ出る。
  ワークフローは終了コードを見なくても `ok` で判定できる
- 1 つのプラットフォームで API が失敗しても（macOS のバージョンの作成が 409 など）、ほかのプラットフォームは続けて、その結果も JSON に残る（全体は `ok: false`）

```json
{
  "command": "prepare",
  "ok": true,
  "version": "1.1.0",
  "bundleId": "jp.shilokuma.AskHub",
  "appId": "…",
  "dryRun": false,
  "platforms": {
    "IOS": {"status": "created", "versionId": "…", "versionString": "1.1.0", "state": "PREPARE_FOR_SUBMISSION", "editable": true, "released": false, "message": "…"},
    "MAC_OS": {"status": "platform-missing", "message": "…"}
  },
  "messages": ["…", "…"]
}
```

プラットフォームごとの `status`:

| サブコマンド | status | 意味 |
| --- | --- | --- |
| すべて | `platform-missing` | App Store Connect のアプリにそのプラットフォームが無い（バージョンが 1 つも無い）。macOS なら飛ばして iOS だけで続ける（`--optional-platforms` に無い iOS なら失敗） |
| `prepare` | `created` / `exists` / `renamed` | 作った / すでにあった / 残っていた編集できるバージョンの `versionString` を書き換えた（`previousVersionString` に元の値） |
| `prepare` | `blocked` | 人が App Store Connect で直す必要がある（下の「編集できるバージョンが残っているとき」）。失敗になる |
| `attach-build` | `attached` / `already-attached` | 最新のビルドを紐付けた（`previousBuildId` に前のビルド）/ すでに紐付いている |
| `attach-build` | `waiting-for-build` / `locked` / `version-missing` | 処理が終わったビルドがまだ無い / 審査中・配信済みなので触らない / そのバージョンが無い |
| `status` | `released` / `not-released` / `version-missing` | 配信済み / まだ / そのバージョンが無い。トップの `released` は、バージョンがあるプラットフォームすべてで配信済みのとき `true`（`error` のプラットフォームがあれば `false`。必須のプラットフォーム（`--optional-platforms` に無いもの。既定は iOS）は、バージョンが無ければ `false`） |
| すべて | `error` | そのプラットフォームの API の呼び出しが失敗した（`httpStatus` に HTTP のステータスコード。通信の失敗では `null`）。失敗になるが、ほかのプラットフォームの結果は残る |

- ビルドは `/v1/builds` を、バージョン（`CFBundleShortVersionString`）・プラットフォーム・`processingState=VALID`・期限切れでないもので探し、`uploadedDate` が最も新しいものを選ぶ。
  release ブランチへの push のたびにビルドが上がるので、審査に出す前なら新しいビルドに差し替える
- ビルドは上がったブランチを区別できない（バージョンとプラットフォームだけで選ぶ）。`develop` の `MARKETING_VERSION` がリリースと同じだと、
  `develop` への push で上がったビルドを紐付けうるので、リリース準備は `develop` の `MARKETING_VERSION` より大きいバージョンでしか始めない。
  前の `v*` タグが無い初回だけは同じ値も許し、Job Summary で注意を出す（「リリース準備」の「バージョンの決まり」）
- 配信済みとみなすのは、`appVersionState` が `READY_FOR_DISTRIBUTION`・`REPLACED_WITH_NEW_VERSION`、または非推奨の `appStoreState` が `READY_FOR_SALE`・`REPLACED_WITH_NEW_VERSION` のとき。
  承認後の公開待ち（`PENDING_DEVELOPER_RELEASE`）や配信の処理中は含めない（手動で公開するまでリリース後作業を始めない）
- 一覧はページングを最後までたどる。429（レート制限）は `Retry-After` の秒数（無ければ 10 秒から倍々）を待って 4 回まで送り直す。`Retry-After` が 120 秒を超えるときは待たずに失敗にして、次の実行に任せる

### 編集できるバージョンが残っているとき

App Store Connect では、編集できる状態（提出準備中・却下など）のバージョンはプラットフォームごとに 1 つしか持てず、残っていると新しいバージョンを作れない。
`prepare` は、残っているバージョンがリリースのバージョン以下（例: プラットフォームを追加したときに自動で作られる `1.0`）なら `versionString` を書き換えて使う。
入力済みの説明文・スクリーンショットは残り、メタデータとスクリーンショットの反映で上書きされる。

残っているバージョンの方が新しい・形が違う・複数ある、または `--other-editable fail` のときは `blocked` で止まる。App Store Connect の画面でそのバージョンの番号を直すか消してから、リリース準備を再実行する。

### 手元で確かめる

```bash
python3 -m unittest discover -s Tools/tests -t .
```

HTTP を偽物（`Tools/tests/fake_app_store_connect.py`）に差し替えて流すので、App Store Connect にはつながず、PyJWT も要らない。PR では Verify/App Store metadata が同じテストを流す。

## リリース準備

`develop` から release ブランチを切り、App Store Connect にバージョン・バイナリ・スクリーンショット・メタデータを用意する（Discussion #605 の「リリース準備」）。
ワークフローは `.github/workflows/release-prepare.yml`（Release/Prepare）。AskHub アプリの「リリース準備」が `workflow_dispatch` で起動する。Actions から手で起動してもよい。

### 流れ

| 順 | すること | 使うもの |
| --- | --- | --- |
| 1 | 入力の検査（下の「バージョンの決まり」） | `Tools/release_prepare.py check` |
| 2 | `develop` の先頭から `release/<v>` を作り、`MARKETING_VERSION` が違えば `[chore] MARKETING_VERSION を <v> にする` を積む | `Tools/release_prepare.py set-version` |
| 3 | 最新情報の下書き `AppStore/whats-new-draft.json` を作り、`[chore] <v> の最新情報の下書きを作る` を積んで push する | `Tools/release_prepare.py draft` |
| 4 | App Store Connect に iOS / macOS のバージョン `<v>` を用意する（「App Store Connect のバージョンとビルド」） | `Tools/release_app_store.py prepare` |
| 5 | release ブランチで Upload・Screenshots/App Store・Metadata/App Store（`dry_run: false`・`app_version: <v>`）を起動する | `gh workflow run … --ref release/<v>` |
| 6 | Job Summary に結果と、人が次にすることを出す（1 の検査で止まったとき・release ブランチを作れなかったときは「次にすること」を出さない） | |

- inputs は `version`（必須）と `resume`（任意。既定 `false`。下の「失敗したとき」）。`develop` 以外から起動すると止まる（`Tools/` は `develop` のものを使うため。
  `resume` でも作業ツリーは `develop` のままで、release ブランチは先頭のコミットで起動するワークフローのファイルの有無を見るだけ）
- run の表示名（`run-name`）は `Release/Prepare <version>`。runs の一覧の API は inputs を返さないので、AskHub アプリ（`WorkflowRun.displayTitle`）はこの名前でどのバージョンの run かを見分けられる。
  inputs は `run-name` の表示にだけ式で使い、`run:` の中には環境変数で渡す
- コミットの作者は `github-actions[bot]`。`GITHUB_TOKEN` での push は新しいワークフローの run を起こさないので、Upload などは 5 で `workflow_dispatch` する。
  同じ理由で、release ブランチの先頭では Build（CI）が動かない（リリース後作業が `main`・`develop` に取り込む前に流す）
- 5 は、release ブランチにファイルが無いワークフローを飛ばして Summary に書く。バイナリは App Store Connect のバージョンが無くても上げられるので、4 が失敗しても Upload は起動する。
  スクリーンショットとメタデータは、4 で iOS のバージョンを用意できた（`created`・`exists`・`renamed`）ときに起動する。macOS だけが `blocked` / `error` のときも iOS には反映し
  （macOS の分は反映の側で飛ばされるか失敗する）、run は最後に失敗にする。iOS を用意できなかったときは起動しない
- リリース準備は同時に 1 つだけ動く（`concurrency`）。macOS のランナーは、Upload の 2 台とスクリーンショットの 1 台を使う
- リポジトリ変数 `ENABLE_DELIVERY=false` のときは 1〜3 だけを行う（App Store Connect には触れない）。`ENABLE_MACOS_DELIVERY=false` のときは 4 を iOS だけで行う

### バージョンの決まり

- 形は `MAJOR.MINOR.PATCH`（0 以上の整数 3 つ。先頭の 0 は不可）。release ブランチは `release/<v>`、タグは `v<v>`
- `v<v>` のタグがあるバージョン（リリース済み）では始めない。`release/<v>` があるときは、`resume` をオンにしたときだけ続きから行う
- **タグの無いほかの release ブランチがあるときは始めない。** App Store Connect の編集できるバージョンはプラットフォームごとに 1 つなので、
  並べて準備すると、前のリリースのバージョンの番号を書き換えてしまう（`prepare` は古い編集できるバージョンを書き換える）。やめたリリースは release ブランチを消す
- **`develop` の `MARKETING_VERSION` より大きいバージョンでしか始めない。** ビルドの紐付け（`attach-build`）はビルドをバージョンとプラットフォームだけで選び、
  上がったブランチを区別できない。同じバージョンだと、`develop` への push で上がったビルドが release ブランチのバージョンに紐付きうる。
  アプリの既定値は `develop` の次のマイナー（`1.0.0` → `1.1.0`）なので、ふつうは当たらない
- **同じ値は、前の `v*` タグ（`MAJOR.MINOR.PATCH` の形のもの）が 1 つも無い初回だけ許す**（App Store の最初のバージョンを `develop` の `MARKETING_VERSION` のまま出すため。PR #627 の ask の回答 B）。
  このときは `MARKETING_VERSION` を書き換えるコミットを積まない。`develop` への push で上がったビルドと release のビルドが同じバージョンになり、
  Release/Sync の紐付けはアップロードの新しいものを選ぶので、Job Summary に注意を出す。審査に出す前に、紐付いたビルドが release ブランチから上がったもの（ビルド番号・アップロードの時刻）か確かめる。
  2 回目以降（`v*` タグがある）は同じ値でも止める
- リリース済みの最新のタグより大きいバージョンでしか始めない

### 最新情報の下書き

`AppStore/whats-new-draft.json`（release ブランチにだけある）。Release/Notes（`release-notes.yml`）が確定して `AppStore/metadata/<言語>.json` の `whatsNew` に書くと消える。
アプリは Contents API でこのファイルを読み、「下書きあり（未確定）」を出す。

```json
{
  "schemaVersion": 1,
  "version": "1.1.0",
  "generatedAt": "2026-10-20T01:02:03Z",
  "base": {"tag": "v1.0.0", "sha": "…"},
  "head": {"ref": "origin/develop", "sha": "…"},
  "initial": false,
  "whatsNew": {"ja": "・起動時に落ちる不具合を直す\n・受信箱を絞り込めるようにする"},
  "omitted": 0,
  "pullRequests": [
    {"number": 2, "title": "起動時に落ちる不具合を直す", "type": "FIX", "url": "https://github.com/…/pull/2",
     "mergedAt": "2026-10-01T00:00:00Z", "epic": null, "included": true},
    {"number": 4, "title": "ワークフローを足す", "type": "CI", "url": "…", "mergedAt": "…", "epic": 7, "included": false}
  ],
  "messages": ["v1.0.0 から 2 件の PR を読み、1 件を最新情報に載せました。"]
}
```

| キー | 意味 |
| --- | --- |
| `schemaVersion` | 形の版（今は `1`）。読む側は知らない版なら読まずに知らせる |
| `version` | リリースのバージョン（release ブランチの `<v>` と同じ） |
| `base` | 前のタグ（`v*` のうちリリースより小さい最大のもの）。初めてのリリースでは `null` |
| `head` | 下書きを作ったときの `develop` |
| `initial` | 前のタグが無い（初めてのリリース）なら `true` |
| `whatsNew` | 言語コード（`AppStore/languages.json` の `language`）→ 本文。4000 字以内。Release/Notes の `whats_new` と同じ形 |
| `omitted` | 4000 字に収まらず「・ほか N 件」にまとめた PR の数 |
| `pullRequests` | 下書きの元にした PR（`develop` に入った順）。`title` は【TYPE】を外したもの、`type` は【TYPE】の中（無ければ `null`）、`epic` は epic の PR から開いたときの epic の PR 番号、`included` は本文に載せたか |
| `messages` | 作ったときの説明（人に向けた文。読む側は表示するだけ） |

作り方:

- `base..develop` を first-parent でたどり、`Merge pull request #N from <owner>/<branch>` のマージコミットを PR とみなす（`develop` に直接入った PR）
- head が `epic/` の PR（epic → `develop` の最終 PR）は、タイトルが「epic/xxx を develop に取り込む」なので、中の子 PR（epic に入った PR）に開いて並べる
- head が `release/` の PR（リリース後作業の release → `develop` の取り込み）は除く
- タイトルは GitHub API（`GITHUB_TOKEN`）で読み、読めなければ（レート制限など）マージコミットの本文の 1 行目を使う
- 本文に載せるのは【FEAT】【FIX】【PERF】と、【TYPE】の無いタイトル。【CI】【DOCS】【TEST】【CHORE】【REFACTOR】などは一覧に `included: false` で残し、本文には載せない
- 本文は「・タイトル」の箇条書き。載せるものが無ければ「細かな改善と不具合の修正を行いました。」
- 前のタグが無い（初めてのリリース）ときは、PR を並べず「はじめてのリリースです。」にする（App Store は最初のバージョンに最新情報を出さない）
- 言語が複数あっても、どの言語にも同じ（日本語の）本文を入れる。確定の前にアプリで直す

### 人がすること

1. 前もって: App Store Connect にアプリを作る（[docs/app-review.md](app-review.md)）。macOS も出すならプラットフォームを追加する（「macOS 版のアップロード」）
2. AskHub の「新しい依頼」→「リリース準備」でリポジトリとバージョンを選んで起動する。手で起動するときは Actions → **Release/Prepare** → Run workflow で、ブランチは `develop` のまま `version` を入れる
3. run の Job Summary で、release ブランチ・App Store Connect のバージョン・起動したワークフローを確かめる。起動された Upload・Screenshots/App Store・Metadata/App Store の run が成功するのを待つ
4. AskHub で最新情報の下書きを確かめ、直して確定する（Release/Notes）
5. 処理が終わったビルドは定期実行（Release/Sync）がバージョンに紐付ける。App Store Connect で審査に提出し、輸出コンプライアンスなどに答える

### 失敗したとき

| 起きたこと | 見るところ・すること |
| --- | --- |
| 「準備を始めませんでした」 | Job Summary の理由のとおり。バージョンを直して起動し直す（何も作っていない） |
| 「タグの無い release ブランチがあります」 | 前のリリースを終える（リリース後作業）か、やめたリリースの release ブランチを消す（App Store Connect の編集できるバージョンも確かめる） |
| App Store Connect のバージョンが `blocked` / `error` | 「App Store Connect のバージョンとビルド」の「編集できるバージョンが残っているとき」。App Store Connect で直してから、同じバージョンで `resume` をオンにして起動し直す（macOS だけのときは iOS のスクリーンショット・メタデータはもう起動している。`resume` で起動し直すと iOS にも上書きで反映し直す） |
| ワークフローの起動に失敗した | 失敗したワークフローを Actions から `release/<v>` を選んで手で起動するか、`resume` をオンにして起動し直す（Upload も起動し直すので、24 時間あたりのアップロード上限に気をつける） |
| push に失敗した | 同じ名前の release ブランチが先にできていないか確かめる。ブランチがあれば `resume` で続ける |

`resume` は、`release/<v>` があってタグが無いときに、ブランチ・コミット・下書きは作り直さず、4・5 だけをやり直す。下書きを作り直したいときは、release ブランチの `AppStore/whats-new-draft.json` を直すか、アプリで確定する。

### 権限・Secrets / vars

- ジョブの権限は `contents: write`（release ブランチの push）・`actions: write`（`workflow_dispatch`）・`pull-requests: read`（PR のタイトル）。`GITHUB_TOKEN` だけを使う
- Secrets は Metadata/App Store と同じ（`APPLE_API_KEY_BASE64`・`APPLE_API_KEY_ID`・`APPLE_API_ISSUER_ID`）。新しい Secret・vars は要らない
- vars は任意の `ENABLE_DELIVERY`・`ENABLE_MACOS_DELIVERY`（上の「流れ」）
- アプリのトークン（Fine-grained PAT）は、Actions の Read and write（起動と run の表示）と Contents の Read（release ブランチ・下書きの読み取り）があればよい

## 最新情報の確定

リリース準備が作った最新情報の下書きを人が確かめて直し、確定した本文を release ブランチに書いて App Store Connect に反映する（Discussion #605 の Q5）。
ワークフローは `.github/workflows/release-notes.yml`（Release/Notes）。AskHub アプリの最新情報の確定が `workflow_dispatch` で起動する。Actions から手で起動してもよい。

### 流れ

| 順 | すること | 使うもの |
| --- | --- | --- |
| 1 | 入力の検査（`version` の形・起動した ref が `release/<v>` か `develop`） | |
| 2 | `release/<v>` があり、`v<v>` のタグが無い（リリース済みでない）ことを確かめる | `Tools/release_notes.py check` |
| 3 | `whats_new` を検査し、release ブランチの `AppStore/metadata/<言語>.json` の `whatsNew` を `{"version": "<v>", "text": "…"}` にして、下書き `AppStore/whats-new-draft.json` を消す | `Tools/release_notes.py apply` |
| 4 | 変化があれば `[chore] <v> の最新情報を確定する` を積んで push する（作者は `github-actions[bot]`） | |
| 5 | release ブランチで Metadata/App Store（`dry_run: false`・`app_version: <v>`）を起動する | `gh workflow run … --ref release/<v>` |
| 6 | Job Summary に結果を出す（言語ごとの字数・書き換えたか・コミット・起動したワークフロー） | |

- inputs は `version` と `whats_new`（どちらも必須）。`whats_new` は言語コード → 本文の JSON の文字列（例: `{"ja":"・受信箱を絞り込めるようにする"}`。形は「最新情報の下書き」の `whatsNew` と同じ）
- `whats_new` の決まり（3 で検査し、1 つでも外れたら何も書かずに止める）:
  - JSON のオブジェクト。キーは `AppStore/languages.json`（release ブランチのもの）の `language` を**すべて**（過不足なく。同じ言語を 2 回書かない）
  - 値は文字列。前後の空白を外して空でなく、4000 字（Python の `len`。App Store Connect の上限）まで。テンプレートの仮の文言（`TODO:`）を含まない
  - 本文は前後の空白を外して書く
- run の表示名（`run-name`）は `Release/Notes <version>`。inputs は `run-name` の表示にだけ式で使い、`run:` の中には環境変数で渡す（`whats_new` は任意の文字列なので、シェルの引数にも載せない）
- `Tools/` は起動した ref（ワークフローのファイルと同じコミット）のものを使い、書き換えるのは release ブランチの作業ツリー。`release/<v>` と `develop` 以外（別のバージョンの release ブランチ・作業中のブランチ）から起動すると止まる
- **同じバージョンで何度起動してもよい。** 本文を変えて起動し直すと上書きする。同じ内容ならコミットを積まず、5 の反映だけをやり直す（Metadata/App Store が失敗したときのやり直しに使える）
- 確定は同時に 1 つだけ動く（`concurrency`）。続けて起動すると、待っているもののうち最後に起動したものだけが動き、間のものは取り消される
- `GITHUB_TOKEN` での push は新しいワークフローの run を起こさないので、確定のコミットで Upload（バイナリのアップロード）は動かない。メタデータは 5 で明示的に起動する
- リポジトリ変数 `ENABLE_DELIVERY=false` のときは 1〜4 だけを行う（App Store Connect には触れない）

### 初めてのリリースの最新情報

App Store Connect は、そのプラットフォームの最初のバージョンに最新情報（`whatsNew`）の欄を持たない（Web の画面にも出ない）。

- Release/Notes は初めてのリリース（前の `v*` タグが無い）でも、確定した本文（下書きの既定は「はじめてのリリースです。」）を `whatsNew` に書く。
  アプリが「確定済み」と見分けられるように、また GitHub Release の本文に使うため。Job Summary に注意を出す
- Metadata/App Store（`Tools/upload_metadata.py`）は、反映先がそのプラットフォームの最初のバージョン（ほかに配信した・配信を終えたバージョンが無い）なら `whatsNew` を送らず、ログに「最初のバージョンなので、whatsNew は書き込みません」と出す。
  説明文などはそのまま反映する。iOS と macOS は別に数える（macOS を後から足したリリースでは、macOS にだけ送らない）
- App Store Connect が最初のバージョンへの `whatsNew` を実際に弾くかは、まだ確かめていない（実機確認の Issue で確かめる）

### アプリからの確定

アプリは `release-notes.yml` を **`release/<v>` の ref で**起動する（inputs は `version` と `whats_new`。`ReleaseWorkflow.notesInputs`）。

- アプリが送る前に見るのは形だけでよい（言語・字数・空でないことの正本はこのワークフローの検査）。止まったときの理由は run の Job Summary に出る
- `release/<v>` を切った時点の `develop` に `release-notes.yml` が無かった release ブランチでは、`release/<v>` の ref では起動できない（dispatch がエラーになる）。そのときは Actions から `develop` を選んで起動する。
  このとき確定は `develop` の `Tools/` で行うが、起動される Metadata/App Store は `release/<v>` で動き、release ブランチの古い `Tools/upload_metadata.py` を使うので、上の「初めてのリリースの最新情報」の `whatsNew` の除外が効かない（初めてのリリースでは、App Store Connect が `whatsNew` を弾くと Metadata/App Store が失敗しうる）
- 確定すると、release ブランチの `AppStore/whats-new-draft.json` が消え、すべての言語の `whatsNew.version` が `<v>` になる（アプリの「確定済み」）

### 人がすること

1. AskHub で最新情報の下書きを確かめ、直して確定する。手で起動するときは Actions → **Release/Notes** → Run workflow で、ブランチは `release/<v>`（無ければ `develop`）を選び、
   `version` と `whats_new`（例: `{"ja":"・受信箱を絞り込めるようにする\n・起動時に落ちる不具合を直す"}`。改行は `\n`）を入れる
2. run の Job Summary で、言語ごとの字数・コミットを確かめる。起動された Metadata/App Store の run の Job Summary で、iOS / macOS に最新情報が書き込まれたかを確かめる
3. App Store Connect で審査に提出する（人が行う）。提出した後（審査中）は App Store Connect の最新情報を書き換えられないので、確定し直しても反映は失敗する

### 失敗したとき

| 起きたこと | 見るところ・すること |
| --- | --- |
| 「確定しませんでした」 | Job Summary の理由のとおり。`whats_new` の問題は 1 行ずつ出る。直して起動し直す（release ブランチは変えていない） |
| 「release/<v> がありません」 | 先にリリース準備（Release/Prepare）を行う。バージョンの打ち間違いも確かめる |
| 「タグ v<v> がすでにあります」 | リリース済み。最新情報は確定し直せない（次のバージョンで書く） |
| release ブランチに push できなかった | 起動した後に release ブランチが進んだ（別の確定・人の push）。同じ内容で起動し直すと最新の先頭に積む |
| Metadata/App Store の起動に失敗した | 確定のコミットは積んである。同じ内容で起動し直すと、コミットを積まずに反映だけを起動し直す。Actions から Metadata/App Store を `release/<v>`・`dry_run` オフで手で起動してもよい |
| Metadata/App Store が失敗した | その run の Job Summary（「App Store のメタデータ」）。バージョンが審査中などで編集できないときは反映できない |

### 権限・Secrets / vars

- ジョブの権限は `contents: write`（release ブランチの push）・`actions: write`（`workflow_dispatch`）。`GITHUB_TOKEN` だけを使う
- このワークフローは App Store Connect の Secrets を使わない（反映は Metadata/App Store が行う）。新しい Secret・vars は要らない。vars は任意の `ENABLE_DELIVERY`

## リリース後作業

App Store で配信されたリリースを `main` と `develop` に取り込み、タグ `v<v>` と GitHub Release を作る（Discussion #605 の Q6・Q7）。
ワークフローは `.github/workflows/release-finish.yml`（Release/Finish）。配信を検知した Release/Sync（`release-sync.yml`）が `workflow_dispatch` で起動する。Actions から手で起動してもよい。

### 流れ

| 順 | ジョブ | すること | 使うもの |
| --- | --- | --- | --- |
| 1 | check | `version` の形・起動した ref（`develop` か `release/<v>`）。`release/<v>` があること、`main`・`develop`・`v<v>` にどこまで入っているか、release ブランチにしかないコミット（`develop..release/<v>`）に AI 帰属行が無いこと | `Tools/release_finish.py check` |
| 2 | build | release の先頭で CI（`_build.yml`。SwiftLint・iOS の UI テスト・AskHubKit・macOS のビルド）を流す。`main`・`develop` への取り込みが済んでいれば飛ばす | `_build.yml` の `ref` |
| 3 | finish | `main` が無ければ release の先頭から作り（初回）、あれば release → `main` をマージコミット（`Merge branch 'release/<v>' into main`）で取り込む | `Tools/release_finish_merge.sh main` |
| 4 | finish | `main` の first-parent のうち release の先頭を初めて含むコミット（取り込んだマージコミット。初回は `main` の先頭）に注釈付きタグ `v<v>` を打つ | `Tools/release_finish.py tag-target` |
| 5 | finish | GitHub Release `v<v>`（タイトルは `<v>`、Latest）を公開する。本文は下の「Release の本文」 | `Tools/release_finish.py notes` |
| 6 | finish | release → `develop` をマージコミットで取り込み、`develop` の `MARKETING_VERSION` を次のパッチにするコミットを足す（下の「develop のバージョン」）。`develop` がもう release を含んでいても（人が PR をマージした後の起動し直し）、`MARKETING_VERSION` が `<v>` 以下ならそのコミットだけを足す | `Tools/release_finish_merge.sh develop`・`Tools/release_finish.py develop-version` |
| 7 | finish | Job Summary に結果を出す | |

- inputs は `version`（必須）だけ。run の表示名（`run-name`）は `Release/Finish <version>`。inputs は `run-name` の表示にだけ式で使い、`run:` の中には環境変数で渡す
- `Tools/` は起動した ref（ワークフローのファイルと同じコミット）のものを使う。`develop` と `release/<v>` 以外から起動すると止まる
- **CI を流している間に release ブランチが進んだら止める**（CI を通っていないコミットを取り込まない）。同じバージョンで起動し直すと、新しい先頭で CI からやり直す
- **同じバージョンで何度起動してもよい。** 済んだ所（`main`・`develop` が release の先頭を含む・タグがある・Release がある）は飛ばし、残りだけを行う。
  タグがあっても、release の先頭を含んでいれば再実行とみなす。取り込みが両方済んでいれば CI も流さない。
  タグが `main` にあって release の先頭を含まない（タグを打った後に release ブランチが進んだ）ときは、`main` とタグは済みとみなし、進んだ release を CI を流してから `develop` にだけ取り込む
  （進んだ分は `main` に入れない。タグと release の共通の祖先が `develop` にもあるとき＝タグの打ち間違いは止める）
- release ブランチは消さない（要らなければ人が消す）。リリース後作業は同時に 1 つだけ動く（`concurrency`）
- コミット・タグの作者は `github-actions[bot]`。マージコミットのメッセージは `Merge branch 'release/<v>' into <main|develop>`（最新情報の下書きは `Merge pull request` だけを PR とみなすので、次のリリースの下書きには入らない）

### GITHUB_TOKEN だけで取り込む仕組み

新しい Secret（PAT・GitHub App）やリポジトリの設定の変更を足さずに、Q6（CI が通ったら自動でマージ・マージコミット）を満たすための作り。

- `GITHUB_TOKEN` で作った PR・push では `build.yml`・`no-ai-attribution.yml` が動かない。そこで、CI は 2 の build ジョブで（`_build.yml` を `workflow_call`）、
  AI 帰属の検査は 1 の check ジョブで（`no-ai-attribution.yml` と同じ正規表現）、取り込む release の先頭に流してから取り込む
- `develop` はブランチ保護で必須チェック「No AI Attribution」（GitHub Actions のチェック）が要る。PR は必須ではないが、push するコミットにもこのチェックが要る。
  取り込みはローカルで `git merge --no-ff` し、できたコミットをいったん一時ブランチ `release-finish/<v>/develop` に push してから、
  先頭に check run「No AI Attribution」（`checks: write`。GitHub Actions のものになるので必須チェックを満たす）を付けて、`develop` に fast-forward で push する。一時ブランチはすぐ消す
  （中断した run の一時ブランチが残っていても、一時ブランチだけは `+` で上書きするので断られない）
- `main` にはブランチ保護が無いので、一時ブランチも check run も使わずにそのまま push する（`main` に必須チェックを足すなら、`develop` と同じ手順に変える）
- AI 帰属の検査は、release ブランチにしかないコミット（`develop..release/<v>`）だけを見る。`develop` に入ったコミットは PR の No AI Attribution を通っている
  （初回の `main` は `develop` の全履歴を含むので、検査ができる前の履歴まで見ない）
- **`GITHUB_TOKEN` は workflows の権限を持てないので、`.github/workflows/` のファイルが変わる取り込みは push を断られる**
  （`refusing to allow a GitHub App to create or update workflow … without workflows permission`）。
  初回は `main` を release の先頭（リモートにあるコミット）から作るだけなので当たらない見込み（未確認。#645 で確かめる）。取り込み待ちの一時ブランチ `release-finish/<v>/pr-<取り込み先>` を作るのも同じ。`develop` への取り込みも、release ブランチでワークフローを直していなければ当たらない。
  **2 回目以降の `main` への取り込みは、前のリリースから `develop` でワークフローを変えていれば断られる**。
  **workflows が変わる取り込みは断られ、PR / Issue を残して人がマージする**（下の「取り込めなかったとき」。PR #644 の ask の回答で今のままと決めた。workflows の権限を持つトークンで自動にする改善は #647）
- push は `--force` を付けない。起動した後に取り込み先が進んでいて non-fast-forward で断られたときは、取り込み先を取り直して 1 回だけやり直す。2 回とも断られたら PR を残して止める

### Release の本文

release の先頭の `AppStore/` から作る（上から順に、あるものを使う）。

1. 確定した最新情報: `AppStore/languages.json` のすべての言語で `AppStore/metadata/<言語>.json` の `whatsNew.version` が `<v>` なら、その `text`
2. 最新情報の下書き: `AppStore/whats-new-draft.json` の `version` が `<v>` なら、その `whatsNew`（「確定する前の下書きから作った本文です」と添える）
3. PR の一覧: 前のタグから release の先頭までに `develop` に入った PR（`- タイトル (#N)`。下書きと同じたどり方で、【TYPE】を外し、CI などの PR も載せる）。無ければ「細かな改善と不具合の修正を行いました。」

言語が 1 つなら本文だけ、複数なら言語ごとに `### <言語>` の見出しを付ける。前のタグがあれば、末尾に `compare/<前のタグ>...v<v>` のリンクを付ける。
Release がもうあるときは本文を変えない（直したいときは GitHub の画面で直す）。

### develop のバージョン

release → `develop` の取り込みの後、`develop` の `MARKETING_VERSION` は配信したバージョン（`<v>`）になる。そのままだと、次に `develop` に push したときの Upload が、
App Store Connect で閉じたバージョン（配信済み）に上げようとして失敗する。そこで、`develop` の `MARKETING_VERSION` が `<v>` 以下なら、**次のパッチ**（`1.1.0` → `1.1.1`）にするコミット
`[chore] MARKETING_VERSION を <次のパッチ> にする` を取り込みのマージコミットの後に足す（`<v>` より大きければ変えない）。

- `develop` への取り込みで止まって人が PR をマージした後も、同じバージョンで起動し直すと、`develop` がもう release を含んでいても `MARKETING_VERSION` が `<v>` 以下ならこのコミットだけを足す
  （取り込みと同じく、一時ブランチ → check run → fast-forward で push する）。人のマージの push では Upload が動き、配信済みの `<v>` に上げようとして失敗することがある（起動し直してバージョンを上げれば、次の push から通る）
- アプリのリリース準備の既定値は `develop` の次のマイナーなので、`1.1.1` → `1.2.0` になり、飛ばない（次のマイナーにすると既定値が `1.3.0` になる）
- リリース準備は `develop` の `MARKETING_VERSION` より大きいバージョンしか受け付けないので、配信した `1.1.0` の不具合を直すリリースは `1.1.2` 以上にする（`1.1.1` は `develop` の TestFlight 用）

### 人がすること

1. ふだんは何もしない（Release/Sync が配信を検知して起動する）。手で起動するときは Actions → **Release/Finish** → Run workflow で、ブランチは `develop` のまま `version` を入れる
2. run の Job Summary で、`main`・タグ・Release・`develop` を確かめる
3. 「取り込めませんでした」のときは、下の「取り込めなかったとき」

### 取り込めなかったとき

コンフリクトしたとき・push を断られたときは、release の先頭から一時ブランチ `release-finish/<v>/pr-<main|develop>` を作り、そこ → 取り込み先（`main` / `develop`）の PR を作って（もうあれば使って）止め、run を失敗にする（AskHub のリリースの進み具合に「リリース後作業 失敗」と出る）。
PR のタイトルは `【CHORE】release/<v> を <main|develop> に取り込む`、本文に理由とすることを書く。
**PR を作れないとき**（リポジトリの Settings → Actions → General の「Allow GitHub Actions to create and approve pull requests」が無効。ask-hub-apple は 2026-10 の時点で無効）は、
代わりに Issue `【CHORE】release/<v> を <main|develop> に取り込めませんでした`（同じタイトルの開いた Issue があれば作らない）で知らせ、人がその一時ブランチから PR を作る。

**`release/<v>` には push しない（release ブランチは進めない）。** コンフリクトは一時ブランチで解く。release の先頭が進むと、起動し直したときに CI を通した先頭・タグと合わなくなり、
人の push で release ブランチの Upload（App Store Connect へのアップロード）も動く。

1. PR のブランチ `release-finish/<v>/pr-<取り込み先>` で、コンフリクトを解く（取り込み先を取り込むなど）
2. PR を**マージコミットで**マージする（Squash しない）。`develop` 宛ての PR には、PR の head（release の先頭）に check run「No AI Attribution」を付けてあるので、
   コンフリクトが無ければそのままマージできる。一時ブランチにコミットを足したときは、人の push なので `no-ai-attribution.yml` が PR で動く
3. Actions → Release/Finish を同じバージョンで起動し直す（済んだ所は飛ばして、タグ・Release・残りの取り込みと、`develop` の `MARKETING_VERSION` を次のパッチにするコミットを行う）。一時ブランチは要らなければ消す

- 起動し直したときに一時ブランチがもうあれば、作り直さずにそのまま使う（人がコンフリクトを解いたコミットは消さない）。前の run の古い release の先頭のままなら fast-forward で進める
- `main` へは止まっているのでタグと Release は作られていない。`develop` への取り込みだけが止まったときは、`main`・タグ・Release はもうある（Release/Sync はタグのある release ブランチを見ないので、起動し直すのは人）
- 誤って `release/<v>` でコンフリクトを解いてしまった（タグを打った後に release が進んだ）ときも、起動し直せば、進んだ release を `develop` にだけ取り込む（上の「流れ」の再実行）

### 失敗したとき

| 起きたこと | 見るところ・すること |
| --- | --- |
| 「始めませんでした」 | check の Job Summary の理由のとおり。何も変えていない |
| 「AI 帰属行があります」 | release ブランチの該当するコミットを直す（release 宛ての PR）。直してから起動し直す |
| 「タグ v<v> がありますが、release の先頭を含まず、このリリースを main に取り込んだコミットでもありません」 | タグの打ち間違い（`main` に無い、または `develop` のコミットに打った）。人が確かめる（タグは消さずに、次のバージョンで出すかを決める）。タグを打った後に release が進んだだけなら止まらない |
| build が失敗した | build ジョブのログ（`_build.yml`）。release ブランチで直してから起動し直す。何も取り込んでいない |
| 「CI を流している間に release が進みました」 | そのまま同じバージョンで起動し直す |
| 「取り込めませんでした」 | 上の「取り込めなかったとき」 |
| 「check run「No AI Attribution」を付けられませんでした」 | `develop` には push していない。理由（gh の HTTP の状態）を見て、`checks: write` が付いているか・GitHub の障害でないかを確かめ、起動し直す |
| 「develop の MARKETING_VERSION: 次のパッチにするコミットを push できませんでした」 | 取り込みは済んでいる。起動し直すか、人が `develop` で `Configs/Project.xcconfig` を次のパッチにする |
| タグの push に失敗した | 同じ名前のタグが先にできていないか確かめる。あれば、release の先頭を含むかを確かめて起動し直す |

### 権限・Secrets / vars

- check・build は `contents: read`。finish は `contents: write`（`main`・`develop`・一時ブランチの push、タグ、Release）・`checks: write`（check run）・`pull-requests: write`（取り込めなかったときの PR）・`issues: write`（PR を作れなかったときの Issue）。`GITHUB_TOKEN` だけを使う
- App Store Connect の Secrets・vars は使わない。新しい Secret・vars は要らない
- PR を残すには、リポジトリの Settings → Actions → General の「Allow GitHub Actions to create and approve pull requests」が要る（無効でも取り込み・タグ・Release は動き、取り込めなかったときに PR の代わりに Issue で知らせる）。この設定は変えなくてよい

## AskHub アプリが読むもの・起動するもの

AskHub アプリは App Store Connect を見られないので、リリースの進み具合は GitHub の情報（release ブランチ・タグ・各ワークフローの run・下書きのファイル）だけで出す。
API と表示の決まりは [docs/protocol.md](protocol.md) の「リリース準備と最新情報の確定」。

| 読むもの | 場所 |
| --- | --- |
| バージョンの既定値 | `develop` の `Configs/Project.xcconfig` の `MARKETING_VERSION` の次のマイナー（`1.0.0` → `1.1.0`。形が `MAJOR.MINOR.PATCH` でなければ既定値を入れない） |
| 準備中のリリース | `release/<v>` のブランチがあって `v<v>` のタグが無いもの |
| 最新情報 | `release/<v>` の `AppStore/whats-new-draft.json`（あれば未確定）と、`AppStore/languages.json` の言語ごとの `AppStore/metadata/<言語>.json` の `whatsNew`（すべての言語で `version` が `<v>` なら確定済み） |
| ワークフローの有無と run | `release-prepare.yml`・`release-notes.yml`・`release-finish.yml`。依頼の種類の「リリース準備」は常に出し、無い（404）リポジトリを選んだときにその旨を出してボタンを押せなくする（一覧を出す前に全リポジトリへ問い合わせない） |

### アプリからのリリース準備

依頼タブの種類で「リリース準備」を選び、リポジトリを選ぶと、バージョンの欄に `develop` の `MARKETING_VERSION` の次のマイナーが入る（書き換えられる。読めなければ空のまま）。
「リリース準備を始める」で確認ダイアログ（`develop` から `release/<v>` を作ること・App Store Connect に iOS / macOS のバージョンを作ること・バイナリのアップロード・メタデータとスクリーンショットの反映）を出し、
`release-prepare.yml` を `develop` で起動する（inputs は `version`）。

- **アプリが止めるもの**: 形が `MAJOR.MINOR.PATCH` でない・`release/<v>` か `v<v>` がすでにある・タグの無い別の release ブランチがある（準備中のリリースを終えてから）・
  リリース準備の run が実行中・起動した直後。`MARKETING_VERSION` との大小はアプリでは判定しない（ワークフローの入力の検査が正本）
- **ワークフローが無い・無効**: `release-prepare.yml` が無い（404。`state` が `deleted` も同じ）リポジトリでは「このリポジトリにはリリースのワークフローがありません」と出し、ボタンを押せない。
  無効にされている（`disabled_manually` など）ときは、Actions で有効にするよう案内する
- **run の表示**: `develop` の `workflow_dispatch` の run の直近の 1 件（状態・`run-name`・開始時刻・GitHub へのリンク）。dispatch は run の id を返さないので、起動してから
  起動の直前に読み直した直近の run より id の大きい run が出るまで「起動しました」と出し、10 秒後に取り直す（ツールバーの「更新」か、iOS では下に引いても読み直せる）。
  端末の時計がずれていても見分けられるよう、開始時刻とは比べない。10 分たっても出なければ押し直せる
- **デモモード**: GitHub に送らず、起動したことにして実行中の run を出す。run は数秒で成功したことになり、始めたバージョンの release ブランチが準備中のリリースになる（アップロード・下書きと進む）

### アプリでのリリースの進み具合と最新情報の確定

依頼タブの「リリース準備」でリポジトリを選び、タグの無い release ブランチ（準備中のリリース）があれば、その進み具合を「準備中のリリース <v>」に出す（iOS のタブはいっぱいなので増やさない）。
GitHub の情報だけで出すので、App Store Connect の処理・審査の状況は出ない。

| 段 | 見るもの | 表示 |
| --- | --- | --- |
| リリース準備 | `develop` の `release-prepare.yml` の `workflow_dispatch` の run のうち、`run-name`（`Release/Prepare <v>`）がこのバージョンの直近のもの | 実行中 / 済み / 失敗（run が見えなくても、release ブランチがあれば済み） |
| アップロード | `release/<v>` の `upload.yml` の直近の run | 実行中 / 済み / 失敗 / まだ。`upload.yml` が無ければ不明 |
| 最新情報 | 下書き（`AppStore/whats-new-draft.json`）と `AppStore/metadata/<言語>.json` の `whatsNew`、`release-notes.yml` の run | 下書きあり（待ち）/ 確定済み / 反映中 / 読めない下書き / どちらも無い。直近の確定の run が失敗していれば、確定済みでも失敗 |
| 配信 | 最新情報が確定済みで、リリース後作業の run がまだ成功していない | 待ち（審査への提出と配信は App Store Connect で人が行う）。リリース後作業の run が成功していれば済み（手で起動したこともあるので「配信を検知した」とは言わない。実行中・失敗の run は配信前に手で起動したものかもしれないので済みにしない） |
| リリース後作業 | `release-finish.yml` の、このリリースの直近の run | 実行中 / 済み / 失敗 / まだ（配信を検知すると自動で始まる）。無ければ不明 |
| タグと Release | `v<v>` のタグ | タグができると準備中のリリースではなくなり、この欄は消える |

`release-notes.yml`・`release-finish.yml` の run は、起動した ref が `release/<v>` か、`run-name` にバージョン（前後が数字・`.` でない `<v>`）が入っているもので見分ける（一覧の API は inputs を返さないため）。
リリース後作業のワークフローには `run-name` にバージョンを入れる。

「最新情報の下書きを確かめて確定する」から最新情報の画面を開くと、言語（`AppStore/languages.json` の順）ごとに下書き（確定済みならその本文）を直せる。
下書きの元にした PR（本文に載せなかったものは灰色で「（載せない）」を付ける）と、作ったときの説明も出す。「確定して反映」で確認ダイアログを出し、`release-notes.yml` を **`release/<v>` で**起動する
（inputs は `version` と `whats_new`。`whats_new` は言語コード → 本文の JSON の文字列で、本文の前後の空白・改行は外す）。

- **アプリが止めるもの**: 本文が空・4000 字を超える（`Tools/upload_metadata.py` と同じく Unicode のスカラー値で数える）・`release-notes.yml` が無い / 無効・
  確定の run が実行中・リリース準備の run が実行中・起動した直後・読めない下書き（`schemaVersion` が知らない値）
- **起動したあと**は、入力中の本文を送った本文（前後の空白を外したもの）にそろえる。確定が反映されて読んだ本文と同じになれば「直した」扱いも終わる
- **読み直しに失敗したとき**は、前に読んだ進み具合と入力中の本文を残し（iOS で最新情報の画面を開いていても閉じない）、理由を最新情報の画面にも出して確定を止める。
  最新情報だけ読めなかったときも、言語と読んだ本文は前のままにする
- **入力中の本文はリリース（リポジトリとバージョン）ごとに持つ**。別のリポジトリを選んで戻ってきても、直した本文は残る（アプリを終えると消える）
- **確定済みのとき**も直して確定し直せる（`release-notes.yml` は同じバージョンで何度起動しても上書きで直せる）
- **起動した run の見分け方**: リリース準備と同じく、起動の直前に読み直した直近の run より id の大きい run が出るまで「起動しました」と出し、10 秒後に取り直す。
  起動の直前の読み直しで実行中の run が見つかって送らなかったときも、すぐに読み直して進み具合に出す
- **リリース後作業**はアプリからは起動しない（Q7 で自動にしたため）。手で起動したいときのために、ワークフローがあれば GitHub の Actions のページへのリンクを出す
- **デモモード**: GitHub に送らず、送ったことにするだけ。サンプルのリポジトリでリリースの各状態を出す（`AskHub/SampleRelease.swift`）

  | リポジトリ | 状態 |
  | --- | --- |
  | ask-hub-apple | 準備中のリリースなし（既定値は 1.3.0）。「リリース準備を始める」で準備中になる |
  | claude-plugins | 準備中（release/0.4.0 のリリース準備の run が実行中） |
  | notti-ios | 下書きあり（release/2.1.0。準備とアップロードが済んだ）。「確定して反映」で run が実行中 → 数秒で成功になり、送った本文で確定済みになる |
  | beat-tap-ios | 初めてのリリース（タグなし） |
  | web-tools | 最新情報を確定済みで、配信待ち（release/1.5.0） |
  | sandbox | 完了（release/0.9.0 のリリース後作業の run が成功した） |
  | dotfiles など | リリースのワークフローが無い |

### アプリのトークンの権限

Fine-grained PAT に **Actions の Read and write**（起動と run の表示。TestFlight への手動アップロードと同じ）と **Contents の Read**（上の表の読み取り）を付ける。
アプリからは push・タグ・Release の作成をしない（ワークフローが `GITHUB_TOKEN` で行う）ので、Contents の Write は要らない。
