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
