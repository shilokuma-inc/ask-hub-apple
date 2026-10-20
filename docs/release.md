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
| `.github/workflows/verify-app-store-metadata.yml`（Verify/App Store metadata） | PR で `AppStore/`・`Tools/` などが変わると、欠損・文字数の上限・Bundle ID を検査する |
| `.github/workflows/app-store-metadata.yml`（Metadata/App Store） | 手動実行で App Store Connect に反映する。既定は dry-run |

- 上限は `description` 4000 字・`keywords` カンマ込みで 100 字・`promotionalText` 170 字・`whatsNew` 4000 字。超えると PR の検査で落ちる
- 反映するのは「編集できる状態」（`PREPARE_FOR_SUBMISSION` など）の iOS のバージョンだけ。審査中・配信済みのバージョンには触らない
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
3. サブタイトル・プライバシーポリシーの URL・カテゴリ・年齢制限は、この仕組みでは反映しない（App 情報の項目のため）。App Store Connect の画面で入力する（値は [docs/app-review.md](app-review.md)）

`workflow_dispatch` はデフォルトブランチ（`develop`）にファイルがあるときしか起動できない。`develop` に入るまでは実行できない。

### Secrets / vars

| 名前 | 種類 | 内容 |
| --- | --- | --- |
| `APPLE_API_KEY_BASE64` | Secret | App Store Connect API Key（`.p8`）を base64 にしたもの。Upload と同じ |
| `APPLE_API_KEY_ID` | Secret | API Key の Key ID |
| `APPLE_API_ISSUER_ID` | Secret | API Key の Issuer ID |
| `ENABLE_DELIVERY` | vars（任意） | `false` にすると Metadata/App Store を実行しない（Upload と同じ）。未設定なら実行する |

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
| `ENABLE_MACOS_DELIVERY` | vars（任意） | `false` にすると Upload と Archive の macOS のジョブだけを実行しない（macOS の署名やアップロードがうまくいかない間、毎回の失敗を止めたいとき）。未設定なら、macOS のプラットフォームの有無を見て自動で決める |

新しい Secret は要らない（`APPLE_API_KEY_BASE64`・`APPLE_API_KEY_ID`・`APPLE_API_ISSUER_ID`・`EXPORT_OPTIONS` は iOS と同じ）。

## App Store のスクリーンショット

App Store のスクリーンショットを、アプリの撮影モードで撮り、App Store Connect に反映する。今は iOS（iPhone・iPad）だけ。

### 仕組み

| ファイル | 役割 |
| --- | --- |
| `AskHub/ScreenshotDemo.swift` | 撮影モード。起動引数で、デモモードのサンプルデータのまま指定の画面（タブ）を開く |
| `AppStore/screenshots.json` | 撮る画面（`scenes`。この順が App Store の並び順）と表示サイズ（`displayTypes`） |
| `AppStore/app.json` | 撮影でビルドするプロジェクト・Scheme・構成（Release）と、撮影モードのファイル（`screenshotDemoSource`） |
| `Tools/capture_screenshots.sh` | 1 つの表示サイズについて、Simulator を作ってビルドし、言語 × 画面ぶん撮る。撮り終えたら Simulator を消す |
| `Tools/derive_screenshots.py` | `deriveFrom` を書いた表示サイズを、撮った表示サイズから縮めて作る（Pillow が要る） |
| `Tools/verify_screenshots.py` | 寸法・アルファ・枚数が App Store Connect に通る形か確かめる |
| `Tools/remove_alpha.swift` | Simulator の画像（RGBA）をアルファの無い PNG に描き直す（撮影スクリプトが使う） |
| `Tools/upload_screenshots.py` | 言語ごとに、その表示サイズのスクリーンショットのセットを入れ直す |
| `.github/workflows/app-store-screenshots.yml`（Screenshots/App Store） | 手動実行で撮って反映する |
| `.github/workflows/verify-app-store-metadata.yml`（Verify/App Store metadata） | PR で、`scenes` が撮影モードの `Scene` にあるか・枚数の上限（10）・表示サイズの設定を検査する |

表示サイズ:

| 表示サイズ | 撮り方 | 寸法 |
| --- | --- | --- |
| `APP_IPHONE_67`（iPhone 6.9 inch） | iPhone 17 Pro Max（無ければ 16 Pro Max）の Simulator で撮る | 1320x2868 |
| `APP_IPHONE_61`（iPhone 6.3 inch） | 6.9 inch を縮めて作る（ubuntu で動く） | 1206x2622 |
| `APP_IPAD_PRO_3GEN_129`（iPad 13 inch） | iPad Pro 13-inch（M5 / M4）の Simulator で撮る | 2064x2752 |

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

### 人がすること

1. App Store Connect に、反映先のバージョン（「準備中」の状態）を作っておく
2. Actions → **Screenshots/App Store** → Run workflow で、`release/**` のブランチを選んで実行する
   - 撮るのはリリースのときだけ（`release/**` 以外では止まる）。撮影の仕組みだけを確かめるときは `allow_non_release` をオンにする（反映はしない）
   - `upload` を外すと撮るだけ。撮れた画像は run の artifact（`screenshots-<表示サイズ>`）から取れる
   - `display_types`・`languages` で一部だけ撮り直せる。6.3 inch だけを指定しても、元の 6.9 inch を撮ってから縮める
3. 反映すると、その言語・表示サイズの既存のスクリーンショットは消えて入れ替わる（編集できる状態のバージョンだけ。審査中・配信済みには触らない）

macOS ランナーの枠を開発のビルドと取り合わないよう、撮影は 1 本ずつ（`max-parallel: 1`、ワークフロー全体で 1 つ）にしている。

Secrets / vars は「App Store のメタデータ」と同じ（`APPLE_API_KEY_BASE64`・`APPLE_API_KEY_ID`・`APPLE_API_ISSUER_ID`、任意の `ENABLE_DELIVERY`）。
`ENABLE_DELIVERY=false` のときは撮るだけで反映しない。
