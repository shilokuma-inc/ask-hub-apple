# クリエイティブアセット（Actions で書き出し、AskHub で確かめ、司令塔が反映する）

[release.md](release.md) の「プロダクトページのヘッダーと検索結果の素材」を、作れる形まで決める設計（#1235）。
iOS 27 以降の App Store に出る、プロダクトページのヘッダー（21:9）と検索結果の画像（3:2）を扱う。この文書ではまとめて「クリエイティブ」と呼ぶ。

状態: 2026-11-23 にユーザーが決め、設計を承認した（下の「決めたこと」。5 つとも A）。実装は「PR の分け方」の順に進める。

## ねらい

- 人は AskHub の画面で案を見て、直してほしいことを書くか承認するだけにする。手元の Mac で書き出したり、画像をコミットしたりしない
- 文言（すべての言語）・色・使う画面の案は Claude が作る（release.md の「チャットでの手直し」）
- 書き出しの雛形（描き方・端末の枠・安全領域）を 1 か所に持ち、直しが全リポジトリに届くようにする
- 初めての版のアプリも、配信中のアプリも、同じ流れで載せる

## ユーザーが決めたこと

2026-11-22・23 に決めた（この設計の前提）。

- 画像は CI（GitHub Actions の macOS ランナー）で書き出し、リポジトリにコミットしない。確かめるのは artifact か AskHub の画面
- 反映は司令塔が行う（スクショと同じ。App Store Connect の鍵は常時オンの Mac の司令塔にしか無い）
- 手元の Mac では作らない
- スクショは各リポジトリの Actions で撮り（app-kit の `app-store-screenshots.yml`）、確かめと App Asset Library への反映は司令塔が行う（[store-screenshots.md](store-screenshots.md)）

## 今の作り

2026-11-21 の全リポジトリの調査と、2026-11-23 に app-kit（v1.0.1）・template-app-ios（develop 1c96372）・oshikatsu-countdown-ios・idfa-vault-ios を読んで確かめた。

### 各リポジトリ

| 見たもの | 分かったこと |
| --- | --- |
| 書き出し | template 系は `Tools/render_creative_assets.sh` が、6.9 インチのスクショのフォルダと `AppStore/creative/src/creative.html` から、ヘッドレスの Chrome で書き出す。出力は `AppStore/creative/<言語>/header.png`（3840x1646）と `search_results.png`（3840x2560）。アルファは `remove_alpha.swift`（`xcrun swiftc`）で落とし、`sips` で寸法を確かめる。macOS が前提 |
| 雛形 | `creative.html` が 1 つのファイルに、色（`:root` の 6 つ）・文言（JS の `copy`。言語ごとに header の `title`・`sub`、search の `title`・`chips` 3 つ。`<em>` で強調）・画面の配置（header は中央と左右の 3 台、search は左に文言とアイコン、右に 2 台）・端末の枠（CSS で描く）を持つ。リポジトリごとに手で直していて、idfa-vault は見出しを中央の 2640px に収め、oshikatsu は言語ごとの書体と長い言語を縮める処理を持つ |
| アプリ名・アイコン | アプリ名は scheme（言語で変わらない。oshikatsu だけ言語ごと）。アイコンは `AppStore/app.json` の `appIcon`（oshikatsu は `.icon` を `ictool` で書き出す） |
| 反映 | `Tools/upload_creative_assets.py` と `app-store-creative-assets.yml`（ubuntu）が、コミットした画像を App Asset Library に上げ、編集できる版の言語ごとに配置する（提出・公開はしない）。参照名に言語・版・MD5 を入れて重なり（409 DUPLICATE）を避ける |
| 画像がある | コミットしている 5 件: idfa-vault-ios（12 言語・約 101 MB）、one-tone-apple（12 言語・約 59 MB）、numer0n-lens-ios・prime-pick-ios（ja・各約 8 MB）、ninjacord-ios（ja・en）。CI で書き出す 1 件: oshikatsu-countdown-ios（撮った 6.9 インチの artifact から同じワークフローで書き出す。上げるのは Ruby の道具） |
| 文言が無い | template 系の 11 件は `creative.html` の文言が `TODO:` のまま（書き出しは警告だけ、反映は止める） |
| app-kit | クリエイティブを持たない。`manifest.json` の `keepIfPresent` で、`upload_creative_assets.py` か `app-store-creative-assets.yml` があるリポジトリでは `app_store_config.py`・`app_store_connect.py`・`remove_alpha.swift` を外さない（`render_creative_assets.sh` は条件に入っていない）。撮影の artifact `screenshots-APP_IPHONE_67` の中身は `<言語>/<番号>_<画面>.png`（1320x2868・アルファなし）で、今の書き出しの入力と同じ形 |
| ランナー | `macos-latest`（macOS 26 arm64）に Google Chrome が入っている（runner-images の README）。日本語・中国語・韓国語・タイ語の書体は macOS の標準のもの。ubuntu は CJK の書体・`sips`・`swiftc` が無いので向かない |

再現性: 同じ入力なら、バイト単位で同じ画像になる（2026-11-21 に、idfa-vault のコミット済みの 24 枚と CI の画面から書き出したものが一致した）。12 言語 × 2 枚の書き出しは約 60 秒。

### AskHub（司令塔）

スクショの流れ（#1195〜#1200・#1203）の部品のうち、そのまま使えるものと、スクショに結びついているものがある。

| そのまま使える | 切り出しが要る |
| --- | --- |
| ワークフローの起動・実行の読み・取り消し（`ReleaseHosting` の `dispatchWorkflow` など。`return_run_details`）、artifact の一覧と zip のダウンロード（リダイレクト先にトークンを付けない） | 起動・見張り・取り込みの段取り（`ReleaseWatch+ScreenshotWorkflow.swift`）が `SubmissionFile`・release ブランチ・`screenshots` に直結している。実行の記録 `CaptureRun` も `SubmissionFile` の中の型 |
| zip の確かめと取り出し（`UnzipArtifactExtractor`。`<言語>/<名前>.png` だけを通す） | artifact の名前 `screenshots-` が決め打ち（`WorkflowScreenshotImport`） |
| 見本（`ScreenshotDiff.preview`・`compare`）と、見本を 1 回のコミットで書く `StateStore.writeTextFiles` | 見本のパス（`StatePath.storeScreenshot`）とクライアントが読んでよいパスの判定に版が入っている |
| ライブラリの画像の予約・送る・`uploaded`・状態・消す、参照名 `askhub-<MD5>` | 配置の種類 `APP_SCREENSHOT` とカテゴリ `APP_SCREENSHOTS_AND_PREVIEWS` が定数（`AppStoreConnectScreenshots`）。参照データは `placementProfileGroups` しか読まない |
| 書き込みの予算（`WriteBudget`）、見回りの周（`beatIfDue`）、Claude の下書き（`ClaudeJob`。`ListingDraft` と同じ形） | ライブラリに上げて待つ処理（`ReleaseWatch+ScreenshotLibrary.swift`）の中身は汎用だが、記録の型がスクショのもの |

## Apple の要件と API

2026-11-23 に Apple の文書（Help と、App Store Connect API の DocC の JSON）で確かめた。

| 置き場所 | 縦横比 | 寸法 | 安全領域 | 形式 |
| --- | --- | --- | --- | --- |
| プロダクトページのヘッダー（`PRODUCT_PAGE_HEADER_ASSET`） | 21:9 | 3840x1646 | 1646x661（x 1097, y 493） | PNG |
| 検索結果（`APP_STORE_SEARCH_RESULTS_ASSET`） | 3:2 | 1920x1280〜3840x2560 | 最大 2168x1030（x 836, y 765） | JPEG・PNG |

- 透過は使えない。文字は短いフレーズにし、すべての言語にローカライズする。価格・URL・著作権の記号・確かめられない受賞・ほかのプラットフォーム・Apple の称号は入れない。アプリの年齢制限によらず 4+ に合わせる
- 端末ごとの寸法は無い（iPhone と iPad で同じ画像。iPadOS 27 以降にも出る）。Mac・Vision Pro の記載は無い
- 画像の上げ方はスクショと同じ（予約 → 送る → `uploaded: true` → 処理）。違うのはカテゴリが `CREATIVE_ASSETS` なことだけ。処理が済むと `specId` が付き、その仕様を受け付ける配置グループを参照データ（`placementTypes[].specMappings`）から引く。ヘッダーと検索結果の配置グループの値は文書に無い
- 配置は `appStoreVersionLocalization`（版の言語）に作る。アプリや言語そのものに結ぶ関係は無い。承認済みの版には作れない（409 `STATE_ERROR.INVALID_STATE`）。ヘッダーは 1 つの配置グループに 1 枚まで
- 版に置いたものは、版の審査に一緒に入り、版が配信されると出る
- 版と別に出す: Help には「Asset Library から単独で提出でき、選んだプラットフォームの最新の版と一緒に審査される」とある。API にも、提出の項目（`reviewSubmissionItems`）の関係に `appAssetLibraryImage` がある（手順の解説は無い）。承認済みの版が 1 つも無いアプリは、最初の版と同じ提出に入れるしかない
- 配信中の版に、承認済みのものを差し替えて出す（Help の Browse Assets → Publish）に当たる API は見つからない。承認済みの版には配置を作れないので、今は App Store Connect の画面でしかできない見込み
- 文書に無いこと: 置かない言語がどうなるか（基準の言語に落ちるか）、新しい版を作ったときに前の版の配置が引き継がれるか

## 決めたこと

2026-11-23 にユーザーが決めた（#1236 で確かめた）。どれも A を選んだ。選んだ案をつなげた全体は、下の「流れ」。

### 1. 書き出す場所と雛形の持ち方

| 案 | 中身 | よい点 | 気になる点 |
| --- | --- | --- | --- |
| **A（決定）** | app-kit に書き出しのワークフローを別に足す（再利用 `app-creative-assets.yml`、呼ぶ側 `app-store-creative.yml`）。雛形（HTML・端末の枠・安全領域の検査）は app-kit に持つ。リポジトリごとの値（文言・色・使う画面・アプリ名）は「案」（下の「案の形」）として状態リポジトリに持ち、司令塔が起動の入力で渡す | 文言を直すたびにコミットが要らない。`TODO:` のファイルが無くなる。雛形の直しが版を広げるだけで届く。撮影のワークフローを触らない | 今の各リポジトリの凝った飾り（idfa の六角形のチップ・oshikatsu の紙吹雪）は雛形に無いので、最初の案で作り直しになる。凝ったものは「デザインした画像」（決めずに残すこと）で補う |
| B | A と同じワークフローと雛形だが、値は各リポジトリの `AppStore/creative.json` に持つ（PR で変える） | 値がコードと一緒に残る。ワーカーの epic でも直せる | 案を直すたびにコミット（か入力で上書き）が要る。新しいリポジトリは `TODO:` に戻る |
| C | app-kit の撮影のワークフローの中で、6.9 インチを撮った後に書き出す。雛形は各リポジトリの `creative.html` を使う | ランナーを増やさない。今の雛形をそのまま使える | リリースの撮影と結びつき、文言だけ直すにも撮り直し（29〜66 分）が要る。並行して撮影のワークフローを直している対応とぶつかる。雛形のずれが残る |

A の書き出しの所要時間の見込み: 6.9 インチを撮る（10〜30 分）+ 書き出す（数分）。文言だけ直すときは、前の実行で撮った 6.9 インチを使い回すので数分で済む。

### 2. 流れ

| 案 | 中身 | 気になる点 |
| --- | --- | --- |
| **A（決定）** | 作って確かめるのは、リリースと別にいつでも行う。人が承認したら、司令塔がライブラリに上げておき、次のリリースの「審査に出す」で版の言語に置く。初めての版も同じ（最初の版と一緒に出すしかないので、そのまま合う） | 承認してから App Store に出るまで、次のリリースを待つ |
| B | A に加え、承認済みの版があるアプリでは、版と別に単独で審査に出す（`reviewSubmissionItems` の `appAssetLibraryImage`）。通ったら、人が App Store Connect の画面で Publish を押す | Publish の API が無く、AskHub の中で終わらない。単独の提出の API の手順が文書に無く、試すと本物の審査に出る |
| C | A に加え、リリースのたびに、承認済みの案で今の画面から書き出し直し、差があれば「審査に出す」で確かめる | 画面が古くならないが、リリースのたびに macOS のランナーを使い、確かめるものが増える |

- B と C は、A の上に後から足せる（決めずに残すこと）
- A でも B でも、承認済みの版が無いアプリは最初の版と一緒に出す

### 3. 文言の決め方

| 案 | 中身 |
| --- | --- |
| **A（決定）** | Claude（常時オンの Mac の、読むだけの Claude）が、すべての言語の文言・色・使う画面の案を作る。材料は、App Store Connect のアプリ名と掲載文、撮れる画面の一覧と基準の言語の 6.9 インチの画像、リポジトリにある `creative.html` の文言（あれば）。人は基準の言語の画像を見て、直してほしいことを書く（Claude が直した案を作り、前の案と並べて見比べられる）か、承認する。参考の画像の添付は後 |
| B | 人が基準の言語の文言を入力し、Claude はほかの言語に訳すだけ |
| C | 今回は Claude の最初の案と承認だけにし、コメントでの手直しは後 |

- `TODO:` のままのリポジトリは、自動では作らない。リポジトリの画面の「ヘッダーと検索結果の画像を作る」から始める。初めての版の「App Store の準備を終える」のチェックリストには、任意の項目として出す
- 画像をコミット済みのリポジトリは、最初の案の材料に今の `creative.html` の文言を渡し、今の文言を引き継げるようにする

### 4. 確かめる画面

| 案 | 中身 |
| --- | --- |
| **A（決定）** | まずは画像を並べる。言語ごとにヘッダーと検索結果を出し、安全領域の枠を重ねて出せる。前の案と、今 App Store にある画像（あれば）と並べて見比べられる。基準の言語を先に出し、ほかの言語は一覧で見て「まとめて承認」 |
| B | App Store での見え方に近い形（iPhone・iPad のプロダクトページの上部と、検索結果の並び）まで作る |

- B は A の後に足せる。Apple のプレビューツールと同じ見え方を作るには、端末ごとの切り抜き方を確かめる必要がある

### 5. 今の各リポジトリの仕組みを外す時期

| 案 | 中身 |
| --- | --- |
| **A（決定）** | AskHub の流れで 1 つのアプリに載せられた（審査に出して置けた）ら、app-kit の次の版で、`manifest.json` の古いクリエイティブのファイル（`app-store-creative-assets.yml`・`Tools/upload_creative_assets.py`・`Tools/render_creative_assets.sh`・`AppStore/creative/`・`AppStore/creative_assets.json`）を `replaces` に入れ、`keepIfPresent` を外す。もう入れ替えたリポジトリと、画像をコミットしたリポジトリからは、外す PR を人の Claude Code のセッションで出す |
| B | リポジトリごとに、AskHub で承認した案を載せ終えたら、司令塔が外す PR を出す |
| C | AskHub の流れができる前に外す |

- コミット済みの画像は、外しても git の履歴に残る（idfa-vault で約 101 MB）。履歴の書き換えは、clone をすべて壊すので行わない
- 今 App Store に出ている画像は、最初の案を確かめる画面で「今の App Store」として並べる（司令塔が配信中の版の配置を読む）。載せるまでは今の画像のまま

## 流れ

| 順 | すること | するのは | 中身 |
| --- | --- | --- | --- |
| 1 | 案を作る | 人（`draftCreativeAssets`） | リポジトリの画面で「ヘッダーと検索結果の画像を作る」を押す（直すときは、直してほしいことを書いて押す） |
| 2 | 文言・色・画面を決める | 司令塔（Claude） | Claude が案（下の「案の形」）を書く。司令塔が形と禁止の語を確かめる |
| 3 | 書き出す | 司令塔 → Actions | 既定のブランチで `app-store-creative.yml` を `workflow_dispatch` する（入力は案。前の実行の 6.9 インチがあれば、その実行の id も渡して撮り直さない） |
| 4 | 見張り・取り込み | 司令塔 | 見回りの周で実行を読み（5 分空ける）、終わったら artifact を落として確かめ、見本を 1 回のコミットで書く。今 App Store にある画像も読む |
| 5 | 確かめる | 人 | 「あなたの番」に出る。画像を見て、直してほしいことを書く（1 に戻る）か、承認する（`approveCreativeAssets`） |
| 6 | ライブラリに上げておく | 司令塔 | 承認した画像を、カテゴリ `CREATIVE_ASSETS` でライブラリに上げる（配置はしない。公開されない）。処理は見回りの周で待つ |
| 7 | 審査に出すときに置く | 人（`submitForReview`）→ 司令塔 | 次のリリースの「審査に出す」に、承認済みの画像と今の App Store の画像が並び、載せるかを選ぶ。載せるなら、司令塔が版の言語ごとに配置を作ってから提出する |

## 書き出し（app-kit）

### 案の形

司令塔が起動の入力（`spec`）に JSON の文字列で渡す。形は app-kit の `schema/creative-spec.schema.json` に置き、司令塔は同じ形を Swift の型で持つ。

```json
{
  "v": 1,
  "layout": "standard",
  "colors": { "background": "#0B1020", "text": "#FFFFFF", "accent": "#7CC4FF" },
  "screens": { "header": ["01_home", "02_detail", "03_settings"], "search": ["01_home", "02_detail"] },
  "locales": [
    {
      "locale": "ja",
      "screenshots": "ja",
      "appName": "素数ピック",
      "header": { "title": "素数を*一瞬*で見抜く", "subtitle": "毎日 3 分の頭の体操" },
      "search": { "title": "数の勘を鍛える", "chips": ["毎日の問題", "ランキング", "広告なし"] }
    }
  ]
}
```

- `layout` は雛形の配置の種類（最初は今の template の配置 1 つ）。`colors` の名前は app-kit の PR で、今の 6 つの色から決める
- `screens` は使う画面（撮影の artifact のファイル名から拡張子を除いたもの）。header は中央・左・右、search は 2 台
- `locales` は App Store Connect の言語ごと。`screenshots` はその言語の撮影の artifact のフォルダ（`build.storeScreenshots.languages` と同じ対応）、`appName` は App Store Connect のアプリ名
- 強調は `*` で囲む。HTML・CSS は受け付けない（雛形が文字として描く）。色は `#RRGGBB` だけ
- 入力の上限（`workflow_dispatch` の入力は全体で 65,535 文字）に、12 言語でも十分に収まる

### ワークフロー

- 呼ぶ側 `managed/.github/workflows/app-store-creative.yml`（`workflow_dispatch`。入力は `spec`・`screenshots_run`）
  - `capture` ジョブ: `screenshots_run` が空のときだけ、app-kit の `app-store-screenshots.yml` を `display_types: APP_IPHONE_67`・`allow_non_release: true`・`upload: false` で呼ぶ（案の言語の撮影のフォルダだけ）
  - `render` ジョブ: app-kit の `app-creative-assets.yml` を呼ぶ。6.9 インチは、`screenshots_run` の実行か同じ実行の artifact `screenshots-APP_IPHONE_67` を `actions/download-artifact`（`run-id`・`github-token`。権限は `actions: read` だけ）で落とす
- 再利用 `app-creative-assets.yml`（macos-latest）: 雛形 `tools/creative/creative.html` に案と画面を渡し、ヘッドレスの Chrome で書き出す。アルファを落とし、寸法を確かめる。アイコンは `AppStore/app.json` の `appIcon`（無ければ載せない）
- 書き出しの検査: 見出しと文言の箱が安全領域（ヘッダーは 1646x661、検索結果は 2168x1030）に収まるか、はみ出して切れていないかを、描いたページの中で測る。はみ出したものは画像を書き出したうえで、結果に書く
- artifact は 2 つ
  - `creative-assets`: `<言語>/product-page-header.png`（3840x1646）・`<言語>/search-results.png`（3840x2560）。どちらも PNG・アルファなし
  - `creative-report`: `report.json`（言語・種類ごとの、はみ出し・安全領域の外の文字・描けなかった理由）
- Secrets は渡さない（書き出しだけで App Store Connect に書かない）
- 雛形は、今の template の配置に、idfa-vault の「見出しを安全領域に収める」・oshikatsu の「言語ごとの書体」「長い言語は折り返さずに縮める」を入れる。Dynamic Island は描かない（app-kit の撮影の画像には写っている）
- app-kit の `self-test.yml` に、fixture の画面（小さな PNG）と見本の案で書き出し、寸法・アルファ・検査の結果を確かめるジョブを足す

## 状態リポジトリと意図

### creative.json（クリエイティブの案と反映）

`repos/<owner>/<repo>/creative.json`（書き手は司令塔）。

```json
{
  "v": 1,
  "repo": "shilokuma-inc/prime-pick-ios",
  "draft": {
    "revision": 2,
    "request": { "approval": { "keyId": "…", "nonce": "…" }, "comment": "見出しをもっと短く", "at": "…" },
    "spec": { "v": 1, "…": "…" },
    "reason": "検索結果では、ランキングを前に出しました",
    "draftedAt": "…",
    "render": {
      "state": "rendered",
      "run": { "id": 123, "url": "…", "dispatchedAt": "…", "status": "completed", "conclusion": "success" },
      "screenshotsRun": 120,
      "images": [
        { "locale": "ja", "kind": "productPageHeader", "md5": "…", "preview": "repos/…/creative/2/ja/productPageHeader.b64", "problems": [] }
      ]
    }
  },
  "previous": { "revision": 1, "spec": { "…": "…" }, "images": [] },
  "approved": {
    "revision": 2, "spec": { "…": "…" }, "images": [], "approval": { "…": "…" }, "at": "…",
    "library": { "total": 24, "ready": 24, "sentAt": "…" }
  },
  "live": { "version": "1.3.0", "images": [{ "locale": "ja", "kind": "productPageHeader", "url": "…" }], "readAt": "…" },
  "placed": [{ "version": "1.4.0", "revision": 2, "at": "…" }],
  "problem": null,
  "updatedAt": "…"
}
```

- `draft.render.state` は `drafting`（Claude が書いている）・`rendering`（Actions で書き出している）・`rendered`（人が確かめる番）・`failed`（`problem` に理由。人は直してほしいことを書いてやり直せる）
- 見本は `repos/<owner>/<repo>/creative/<revision>/<言語>/<種類>.b64`（幅 600 の JPEG を base64 にした文字。1 回の書き出しの見本を 1 回のコミットで書く。スクショと同じ）。元の画像は常時オンの Mac に置き、状態リポジトリには置かない。見本は今の案・前の案・承認した案の 3 つの版だけ残し、ほかは次の書き込みで消す
- `previous` は前の案（見比べるため）。`approved` は人が承認した案（次のリリースで置くもの）。`live` は配信中の版に置かれている画像（今の App Store）。`placed` は置いた版

### 意図

| `kind` | 対象 | `targetVersion` | `payload` |
| --- | --- | --- | --- |
| `draftCreativeAssets` | リポジトリ（`{ "type": "creative", "id": "<owner/repo>" }`。封筒の `repo` が対象） | 人が見たときの案の `revision`（案が無ければ `0`） | `comment`（直してほしいこと。最初の案なら空でよい。2,000 文字まで） |
| `approveCreativeAssets` | 同上 | 人が見た案の `revision` | 空。書き出しが終わった（`rendered`）案だけ受け付ける |
| `submitForReview`（足す欄） | リリースを始めた版 | 今のまま | `creative`（`{ "revision": <承認した案> }`。載せないなら送らない） |

- 書き出しの途中に `draftCreativeAssets` が来たら、その実行を取り消してから新しい案を書く
- 承認は、`approved` を上書きする（前に承認した案は、置いていなければ捨てる）

## 司令塔

- 起動・見張り・取り込みは、スクショの段取りから「実行の記録」と「保存先」を引数にした共通の部品に切り出して使う（`CaptureRun` を共通の型にする）。打ち切りは 3 時間（撮影 10〜30 分 + 書き出し）
- 起動は既定のブランチ（`repo.json` の base）。送る前に記録に `dispatchedAt` を書き、送った後に落ちて id を書けなければ、スクショと同じく一覧から探す
- ワークフローが無い（404）ときは、app-kit の版が古いので、`problem` に「app-kit を v1.1.0 以上に広げる」と出す
- 取り込み: 2 つの artifact を落とす。PNG・寸法（3840x1646・3840x2560）・アルファなし（PNG の色の種類）・言語のフォルダが案の言語と同じかを確かめる。`report.json` は 1 MB までの JSON として読み、`images[].problems` に写す
- 今の App Store: 配信中の版の言語ごとの配置（`filter[placementType]` に 2 つの種類）を `include=image` で読み、画像の URL を `live` に書く。見比べは画素で行う（スクショと同じ）
- 承認の後: 承認した画像を参照名 `askhub-<MD5>` でライブラリに上げる（カテゴリ `CREATIVE_ASSETS`）。処理中は消さずに待ち、`FAILED` はその画像の `problems` に Apple の理由を書く（人は直して案を作り直す）
- 審査に出すとき: `submit.creative` があれば、編集できる iOS の版の言語ごとに、種類ごとの配置を作る。配置グループは、処理の済んだ画像の `specId` を受け付ける配置グループを参照データから引く（決め打ちしない）。同じ画像の配置はそのまま、違う画像の配置は消してから作る。案に無い言語には置かない（今ある配置にも触らない）
- App Asset Library のクライアントは、配置の種類とカテゴリを引数にする（スクショは今の値のまま）

## クライアント

- リポジトリの画面に「App Store のヘッダーと検索結果」の節: 今の様子（まだ無い・案を書いている・書き出している・確かめる番・承認済み（次のリリースで載せる）・載せた版）と「作る」「見る」
- 案を確かめる画面: 言語を選ぶ（基準の言語が先）、ヘッダーと検索結果の画像、安全領域の枠の表示の切り替え、前の案・今の App Store と見比べ、検査の結果（はみ出しなど）、Claude の理由、「直してもらう」（直してほしいことを書く）と「承認する」
- 「あなたの番」に「ヘッダーと検索結果の案を確かめる」を出す（`rendered` の案があり、承認していないとき）
- 「審査に出す」のシートに「ヘッダーと検索結果」の節: 承認済みの案と今の App Store の画像を並べ、載せるかを選ぶ（既定は載せる）

## 安全

- 案は人の意図（`draftCreativeAssets`・`approveCreativeAssets`）を受けたときだけ作る。Claude の材料のうち、リポジトリの中身（`creative.html` など）は public なので、データとして渡す（指示として読まない）
- 司令塔が案を確かめる: 形（スキーマ）、文字数、色の形、URL・メールアドレス・著作権の記号・通貨の記号と価格らしい数字の無いこと
- 雛形は案の文字を文字として描く（`textContent`）。HTML・CSS・JS は案から受け付けない
- 書き出しのワークフローには Secrets を渡さない。`GITHUB_TOKEN` の権限は `contents: read`・`actions: read` だけ
- artifact はデータとして扱い、スクショと同じく取り出す前に一覧を確かめる（パス・大きさ・PNG の印）
- App Store Connect への書き込み（ライブラリに上げる・配置する）は、人の承認（`approveCreativeAssets`・`submitForReview`）を受けた後だけ

## API の予算

| すること | GitHub の REST | 内容を作る要求 | App Store Connect |
| --- | --- | --- | --- |
| 1 つの案の書き出し | 起動 1・見張り 4〜18・artifact の一覧 1・落とす 2 | 見本 3・記録 3 前後 | 今の App Store の読み 2 + 言語の数 |
| 承認 | — | 記録 2 前後 | 1 枚 3 回 + 処理の確かめ（12 言語で 24 枚、80 回前後） |
| 審査に出す | — | — | 言語ごとに配置の読み 1・消す・作る（12 言語で 50 回前後） |

## 確かめ方

1. ユニットテスト: GitHub と App Store Connect は偽物で、案 → 起動 → 見張り → 取り込み → 承認 → ライブラリ → 置く、を流す。app-kit は `self-test.yml` で書き出しを流す
2. App Store Connect の読むだけの確かめ（ユーザーの承認を得て司令塔を更新してから）: 参照データのヘッダーと検索結果の配置グループ・仕様・上限、配信中のアプリ（idfa-vault-ios・prime-pick-ios など）の版の言語にクリエイティブの配置があるか、新しく作った編集できる版に前の版の配置が引き継がれているか
3. 試しの書き出し（ユーザーの承認のうえ）: app-kit v1.1.0 を試しの 1 本に入れ、司令塔から 1 回書き出して artifact とクライアントの見本を確かめる
4. ライブラリに上げる（ユーザーの承認のうえ）: 承認済みの版があるアプリで承認し、ライブラリに上がって処理が済むまで（配置はしない。公開されない）
5. 審査に出すときに置く（ユーザーの承認のうえ）: 次のリリースで置いて提出するか、そのときにユーザーに確かめる

## PR の分け方

それぞれ独立してマージでき、人が案を作るまで今の動きを変えない。

| 順 | どこ | 中身 | 待つもの |
| --- | --- | --- | --- |
| 0 | ask-hub-apple | この設計の文書 | — |
| 1 | ask-hub-apple | プロトコル: `creative.json`・意図 `draftCreativeAssets`・`approveCreativeAssets`・`submitForReview` の `creative`・見本のパス（スキーマ・ベクタ・Swift の型・protocol.md） | #1232・#1224 のマージ（意図の一覧・`IntentSender` が重なる） |
| 2 | app-kit | 雛形と書き出しの道具、案のスキーマ、`app-creative-assets.yml`・`app-store-creative.yml`、`manifest.json`、`self-test.yml`。v1.1.0 | 撮影を並行させる app-kit の PR のマージ（呼ぶ撮影のワークフローの入力が変わりうる） |
| 3 | ask-hub-apple | 司令塔: App Asset Library のクライアントの配置の種類・カテゴリの引数、参照データの `placementTypes`・`imageSpecs`、読むだけの確かめの道具 | — |
| 4 | ask-hub-apple | 司令塔: Claude の案（材料・下書き・直し・確かめ） | 1 |
| 5 | ask-hub-apple | 司令塔: 書き出しの起動・見張り・取り込み・見本・今の App Store の読み（スクショの段取りから共通の部品を切り出す） | 1・2・撮影を並行させる司令塔の PR のマージ（`ReleaseWatch+ScreenshotWorkflow.swift` が重なる） |
| 6 | ask-hub-apple | 司令塔: 承認の後にライブラリに上げる・審査に出すときに置く | 3・5 |
| 7 | ask-hub-apple | クライアント: リポジトリの節・案を確かめる画面・あなたの番・審査に出すシートの節 | 1 |
| 8 | app-kit・各リポジトリ | 古い仕組みを外す（決めたこと 5） | 通しの確かめ |

文書（release.md・protocol.md・app-kit.md・operations.md）と LEARNINGS.md は、各 PR で変えた所を直す。司令塔の PR をマージしたら、ユーザーの承認を得て常時オンの Mac の司令塔を更新する。

## 決めずに残すこと

- デザインした画像を使う（release.md の「作り方は 2 つ」の 2 つ目）: 人が添付した画像を、書き出しを通さずに確かめて載せる。季節の企画や、雛形に無い飾り（今の各リポジトリの凝った雛形）はこれで補う
- 版と別に単独で審査に出し、配信中の版で公開する（決めたこと 2 の B）。Publish の API が出るか、単独の提出を試してよいアプリが決まったら
- リリースのたびに書き直す（決めたこと 2 の C）
- App Store での見え方に近い確かめの画面（決めたこと 4 の B）、参考の画像の添付
- ヘッダーの動画（API は画像と同じ形。`appAssetLibraryVideos`）
- アプリごとの「デザインの決まり」のファイル（release.md の「デザインの方針」）。最初は Claude の案の材料に、前に承認した案を渡すだけにする
