# リリース

App Store に出すための今のワークフロー（メタデータ・スクリーンショット・Upload）と、人がすること・必要な Secrets をまとめる（Discussion #605）。
App Store Connect に出す値と審査で指摘されやすい点は [docs/app-review.md](app-review.md) を参照する。

ワークフローは、テンプレート（[shilokuma-inc/template-app-ios](https://github.com/shilokuma-inc/template-app-ios)）と見比べやすいよう、なるべく同じ形で置いている。

> **今のワークフローの文書。** ここにあるのは、App Store のメタデータ・スクリーンショット・macOS 版のアップロード・Upload（develop への push で TestFlight に上げる）。
> 今の仕組み（2026-10）のリリースのワークフロー（Release/Prepare・Notes・Sync・Finish）と道具（`Tools/release_*.py`）は、一度も流れないまま #1087 で外した。前の説明はタグ `legacy-final` のこの文書にある。
> 新しいリリースの流れ（司令塔が配信を見つけて後作業をする・人が AskHub で押す）は [renewal/release.md](renewal/release.md) で、段階 5 で作る（[renewal/plan.md](renewal/plan.md) の「段階 5 の順」）。

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
  App Store Connect は、そのプラットフォームの最初のバージョン（ほかに配信した・配信を終えたバージョンが無い）に最新情報の欄を持たないので、`whatsNew` が書いてあっても送らず、ログに「最初のバージョンなので、whatsNew は書き込みません」と出す。
  説明文などはそのまま反映する。iOS と macOS は別に数える（macOS を後から足したリリースでは、macOS にだけ送らない）。App Store Connect が最初のバージョンへの `whatsNew` を実際に弾くかは、まだ確かめていない
  - リリースのたびの `whatsNew` を書く流れは、段階 5 の新しいリリースの流れで作る（[renewal/release.md](renewal/release.md)。前の Release/Notes は外した）
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
- アドホック署名のアーカイブには push のエンタイトルメント（`com.apple.developer.aps-environment`）を付けられないので、アーカイブの後に
  `Tools/embed_archive_entitlements.py embed` で sandbox などに足して署名し直し、Export に引き継がせる（iOS と同じ仕組み）。
  Export の後に pkg の中の .app に残ったかを確かめ（`check`）、落ちていれば App Store Connect に上げずに止める
- Mac App Store にはカテゴリ（`LSApplicationCategoryType`）が要るので、`AskHub/Info.plist` に `public.app-category.developer-tools`（開発ツール。[docs/app-review.md](app-review.md) のカテゴリと同じ）を書いている
- Archive（`main` への push）も、iOS と macOS の両方を Export まで確かめる（アップロードはしない）
- 実行中の macOS のランナーは、iOS と macOS で 1 回の Upload につき 2 台。org 全体で同時に 5 台までなので、続けて push すると待たされることがある

### 人がすること

1. [App Store Connect](https://appstoreconnect.apple.com/apps) でアプリを開き、「プラットフォームを追加」（サイドバーのプラットフォームの横の「＋」）から macOS を追加する。
   追加すると macOS のバージョン（提出準備中）ができ、次の Upload から macOS のビルドも上がる（それまでは Job Summary に「macOS のアップロードを飛ばしました」と出る）
2. 追加した後、Actions → **Upload** → Run workflow で `develop`（または release ブランチ）を選んで実行し、`upload-macos / archive` が成功して TestFlight（macOS）にビルドが並ぶのを確かめる
3. macOS の審査への提出・輸出コンプライアンスの回答は、iOS と同じく人が App Store Connect で行う

### Mac に TestFlight の版を入れる

TestFlight の版は配布用の署名なので、Mac を Apple Developer にデバイス登録しなくても入れられる（Xcode から自動の署名で入れると、その Mac がデバイス登録される）。

1. App Store Connect の TestFlight で、macOS のビルドが内部テストのグループに入っているかを確かめる（自動の配信を切っているグループには、ビルドを足す）
2. 同じグループの設定で「iPhone と iPad の App を Apple シリコン搭載の Mac でテスト」（Test iPhone and iPad Apps on Apple Silicon Macs）をオフにする。
   オンだと、Apple シリコンの Mac の TestFlight から iPad 版が入る（Mac 版のビルドがあっても）。iPad 版は、メニューバーに「設定…」が無く、端末の鍵のラベルが `iPad` になる
3. Mac に [TestFlight](https://apps.apple.com/app/testflight/id899247664) を Mac App Store から入れ、内部テスターの Apple ID でサインインする
4. TestFlight の AskHub から「インストール」する。新しいビルドが上がると、TestFlight が更新する（自動の更新を切っていなければ）
5. TestFlight の版は production の APNs に登録する。ビルドは 90 日で期限が切れるので、それまでに Upload を流す

入れた後に、状態リポジトリにつなぐ。

1. AskHub → 設定…（⌘,）で、見るデータを状態リポジトリにし、状態リポジトリの名前（既定 `shilokuma-inc/askhub-state`）を確かめる
2. 状態リポジトリの Contents の読み書きだけを許した Fine-grained token を、その Mac 用に作って入れる（端末ごとに分けると、その端末だけ取り消せる）
3. 「この端末の鍵」に出る `askhub key add …` を、非常口の鍵を入れた Mac のターミナルで流す（[docs/renewal/operations.md](renewal/operations.md) の「非常口」）。
   `--label` は表示用の名前なので、Mac が複数あるときは見分けられる名前に変えてよい（1〜64 文字。空白や括弧を入れるときは引用符で囲む）。記録は追記だけなので、後から名前だけは変えられない
4. 「登録を確かめ直す」で登録済みになると通知の許可を求めるので、許可する。状態リポジトリの `devices/<鍵の id>.json` に `platform: macos`・`environment: production` で宛先が書かれる

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
| `AskHub/ScreenshotDemo.swift` | 撮影モード。起動引数で、デモのデータのまま指定の画面を開く |
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

- `-screenshot-demo` だけでデモのデータ（`DemoScenario.standard`）になり、GitHub にもトークンにもつながない。
  設定のデモの場面（`demoScenario`）は読まず、撮っている間に画面が変わらないよう機械の反応も起こさない
- `-screenshot-scene` には `ScreenshotDemo.Scene` の rawValue（今は `action` / `request` / `decisions` / `status` / `verification`）を渡す。
  知らない値・値なしは「あなたの番」になる。名前は、リニューアルで画面を作り直した後も `screenshots.json` に合わせて前のまま残している
- 撮影は Release でビルドするので、撮影モードは `#if DEBUG` にしていない

### 画面（scene）の足し方

1. `AskHub/ScreenshotDemo.swift` の `enum Scene: String` に `case` を足し、`section` と `route` で開く画面を返す。
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
（`RootView` をデモのデータで、`ScreenshotDemo.Scene` の画面を開いた状態）をウィンドウに出し、
`cacheDisplay(in:to:)` でタイトルバー（タブとツールバー）ごと PNG にする。これなら画面収録の許可は要らない。

- 寸法は `screenshots.json` の `sizes` の先頭（2880x1800）。1440x900 ポイントのウィンドウを 2 倍で描く。外観はライト
- 撮る画面・言語・寸法・出力先は `capture_mac_screenshots.sh` が JSON に書き、`TEST_RUNNER_ASKHUB_SCREENSHOT_PLAN` でテストに渡す（`xcodebuild` は `TEST_RUNNER_` を外した名前でテストに渡す）。
  この環境変数が無いとテストは飛ばされるので、Build（`build.yml`）の Unit テストでは撮らない
- テストは `@testable import` でアプリの View を使うので Debug でビルドする（iOS の撮影は Release）。デモのデータは同じ
- 言語はロケール（`languages.json` の `appleLocale`）だけを渡す。アプリの文言は日本語だけなので、言語を足すときは文言の切り替えも見直す
- アプリそのものを起動するわけではないので、`-screenshot-demo` / `-screenshot-scene` の起動引数は使わない（`ScreenshotDemo.Scene` の `section` と `route` は同じものを使う）。
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

## AskHub アプリとの関係

リニューアルで、アプリのリリースの画面（リリース準備を始める・進み具合・最新情報の確定）を外した。今のアプリは、リポジトリの画面に「リリースの画面は、リリースの段階で作ります」と出すだけで、この文書のワークフローを起動も表示もしない。
上の各ワークフローは、Actions から手で起動する（Upload は develop への push で動く）。前のアプリの画面の決まり（読むもの・起動するもの・止めるもの・デモモード・トークンの権限）は、タグ `legacy-final` のこの文書と `docs/protocol.md` にある。

新しいリリースの流れ（司令塔が App Store Connect を読み、審査に出す・配信するは人が AskHub で押す）は [renewal/release.md](renewal/release.md) にあり、段階 5 で作る（[renewal/plan.md](renewal/plan.md) の「段階 5 の順」）。
新しいアプリのトークンは状態リポジトリだけを読み書きするので、ここのワークフローの起動に要る Actions の権限は持たない。
