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
  最初のバージョン（1.0.0）には最新情報の欄が無いので書かない
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
- 結果は JSON で標準出力に出る（人に向けた説明は標準エラー）。終了コードは 0 = 成功・1 = 失敗（`error` に理由）・2 = 引数の誤り

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
| `status` | `released` / `not-released` / `version-missing` | 配信済み / まだ / そのバージョンが無い。トップの `released` は、バージョンがあるプラットフォームすべてで配信済みのとき `true` |

- ビルドは `/v1/builds` を、バージョン（`CFBundleShortVersionString`）・プラットフォーム・`processingState=VALID`・期限切れでないもので探し、`uploadedDate` が最も新しいものを選ぶ。
  release ブランチへの push のたびにビルドが上がるので、審査に出す前なら新しいビルドに差し替える
- 配信済みとみなすのは、`appVersionState` が `READY_FOR_DISTRIBUTION`、または非推奨の `appStoreState` が `READY_FOR_SALE`・`REPLACED_WITH_NEW_VERSION` のとき。
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

## AskHub アプリが読むもの・起動するもの

AskHub アプリは App Store Connect を見られないので、リリースの進み具合は GitHub の情報（release ブランチ・タグ・各ワークフローの run・下書きのファイル）だけで出す。
API と表示の決まりは [docs/protocol.md](protocol.md) の「リリース準備と最新情報の確定」。

| 読むもの | 場所 |
| --- | --- |
| バージョンの既定値 | `develop` の `Configs/Project.xcconfig` の `MARKETING_VERSION` の次のマイナー（`1.0.0` → `1.1.0`。形が `MAJOR.MINOR.PATCH` でなければ既定値を入れない） |
| 準備中のリリース | `release/<v>` のブランチがあって `v<v>` のタグが無いもの |
| 最新情報 | `release/<v>` の `AppStore/whats-new-draft.json`（あれば未確定）と、`AppStore/languages.json` の言語ごとの `AppStore/metadata/<言語>.json` の `whatsNew`（すべての言語で `version` が `<v>` なら確定済み） |
| ワークフローの有無と run | `release-prepare.yml`・`release-notes.yml`・`release-finish.yml`。無い（404）リポジトリでは「リリース準備」を出さない |

### アプリのトークンの権限

Fine-grained PAT に **Actions の Read and write**（起動と run の表示。TestFlight への手動アップロードと同じ）と **Contents の Read**（上の表の読み取り）を付ける。
アプリからは push・タグ・Release の作成をしない（ワークフローが `GITHUB_TOKEN` で行う）ので、Contents の Write は要らない。

