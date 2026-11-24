# App Store のスクショ（Actions で撮り、司令塔で確かめて反映する）

[release.md](release.md) の「スクショ」（#1173・#1181・#1184 で作った作り）を、撮る場所から作り直す設計（#1192）。
2026-11-21 の全リポジトリのスクショまわりの調査で、撮る場所（GitHub Actions か手元の Mac か）よりも、App Store Connect への反映と、AskHub に入口が無いことが問題だと分かった。
推奨は「撮影は GitHub ホストの macOS ランナー（各リポジトリの既存のワークフロー）で行い、確かめと反映は AskHub の司令塔にまとめる」で、この文書はその設計。

状態: 2026-11-22 にユーザーが決めた（下の「決めたこと」）。実装は「PR の分け方」の順に進める。

## ねらい

- 人が「リリースを始める」を押したら、あとは「審査に出す」画面で撮れた画像を確かめて承認するだけで、スクショが App Store Connect に反映される
- 撮影で Mac mini（M2・メモリ 8 GB・ビルドの枠 1）を epic のビルドと取り合わない
- 初めての版（配信中の版が無い）・iPhone Duo・リリースの途中の撮り直しを扱う
- 見本の書き込みで、司令塔の書き込みの予算（1 分 20 回・1 時間 200 回）を食わない
- App Store Connect の取り込みが何時間かかっても、ランナーや見回りを止めない

## 今の作りと詰まる点

2026-11-22 の develop（61bc54be）と、同じ日にマージした #1185（App Asset Library への移行と iPhone Duo。0c338875）を読んで確かめた。

| 詰まる点 | 中身 |
| --- | --- |
| 撮り方が合わない | 撮り方は「UI テストの添付（`XCTAttachment`）」だけ。この形の UI テストを持つのは OshiCon だけで、template 系の 16 件は「起動引数の撮影モード」（`-screenshot-demo -screenshot-scene <名前>`）と、それを使う `.github/workflows/app-store-screenshots.yml` を持つ |
| Mac mini を取り合う | 司令塔がビルドの枠（1）を借りて撮るので、撮っている間は epic のビルドが止まる |
| 書き込みの予算 | 差のある画面の見本を、1 枚ごとに Contents API で状態リポジトリに書く。2026-11-21 は回答の意図が続いただけで予算が尽き、周が最大 597 秒止まった |
| 初めての版 | 配信中の版が無いと「前回の App Store のスクショが無い」で `failed`。登録 9 本のうち 6 本がまだ配信前 |
| 撮り直せない | release ブランチを直しても撮り直さない（リリースをやめて始め直すしかない） |
| 取り込みを待ち切れない | 審査に出すとき（#1185）に、上げた画像の処理を 1 枚ずつ約 2.5 分待ち、終わらなければ投げてやり直す。やり直しでは、処理中の画像（`UPLOAD_COMPLETE`）を「置けない」とみなして消し、上げ直すので、Apple が混んで 1 枚 20 分を超える日は終わらない |
| 旧 API の画像 | #1185 は旧 API（appScreenshotSets）を読まず、配信中の版の配置が読めなければ `failed` にする。template 系の反映（`Tools/upload_screenshots.py`）は旧 API で上げているので、配信中のアプリはどれも比べられない恐れがある（下の「旧 API で上げてある画像」） |

確かめて、詰まらないと分かったこと:

- 撮っている間（`capturing`）は、記録の `awaitsSubmission` が false なので、クライアントに「審査に出す」は出ず（`SubmissionDetailView`）、司令塔も `submitForReview` を断る（`SubmissionHandlers`）。「審査に出す準備ができました」も、スクショが決着してから出る（`SubmissionFile.isPrepared`）

## 新しい流れ

| 順 | すること | するのは | 中身 |
| --- | --- | --- | --- |
| 1 | リリースを始める | 人（`startRelease`） | 今のまま |
| 2 | 撮影を起動する | 司令塔 | release ブランチを作ったら、そのリポジトリの撮影のワークフローを、release ブランチで `upload: false` にして `workflow_dispatch` する（`return_run_details: true` で run の id を持つ） |
| 3 | 撮影を見張る | 司令塔 | 見回りの周で、run の状態を読む（5 分以上空ける） |
| 4 | 取り込んで比べる | 司令塔 | run が終わったら artifact を落とし、配信中の版のスクショと比べる。初めての版は「すべて新しい」にする。見本は 1 回のコミットで状態リポジトリに書く |
| 5 | App Asset Library に上げておく | 司令塔 | 差のある画像を、ライブラリに上げておく（配置はしない）。取り込みの完了は見回りの周で待つ（下の「決めたこと」の 2） |
| 6 | 準備ができた | 司令塔 | スクショが決着したら（取り込みまで終わったか、撮れなかったか）、ほかの準備とそろったところで「審査に出す準備ができました」を出す |
| 7 | 確かめて審査に出す | 人（`submitForReview`） | 「審査に出す」画面で Before / After（初めての版は After だけ）を確かめ、画面ごとに「前のままにする」を選んで押す。撮り直したいときは「撮り直す」（`retakeScreenshots`） |
| 8 | 置いて提出する | 司令塔 | 承認した画像の配置を作り、余った配置を消し、並べ直してから提出する（今の #1185 の置き方） |

## 撮り方の設定

`repo.json` の `build.storeScreenshots` に、撮り方の種類 `capture` を足す。

```json
"storeScreenshots": {
  "capture": "actions",
  "workflow": "app-store-screenshots.yml",
  "baseLocale": "ja",
  "languages": { "ja": { "language": "ja" }, "en-US": { "language": "en" } },
  "artifacts": {
    "IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE": "APP_IPHONE_67",
    "<6.3 インチの配置グループ>": "APP_IPHONE_61",
    "<iPhone Duo の配置グループ>": "APP_IPHONE_DUO",
    "<iPad 13 インチの配置グループ>": "APP_IPAD_PRO_3GEN_129"
  }
}
```

| `capture` | 撮り方 | 使う欄 |
| --- | --- | --- |
| `actions` | リポジトリの撮影のワークフロー（template 系の `app-store-screenshots.yml`）を起動し、artifact を取り込む | `workflow`（`.github/workflows/` の下のファイル名）、`artifacts`（配置グループごとの、artifact の表示サイズの名前。artifact は `screenshots-<表示サイズ>`）、`languages`（App Store Connect の言語ごとの、artifact のフォルダの言語。template の `AppStore/languages.json` の `language`）、`baseLocale` |
| `uiTest`（省いたとき） | 今の #1173 の作り（常時オンの Mac で UI テストを流し、添付を取り出す）。OshiCon など | 今の欄（`test`・`environment`・`languageVariable`・`regionVariable`・`languages`・`baseLocale`・`displayTypes`） |

- 撮らないリポジトリは、今までどおり `storeScreenshots` を書かない
- 配置グループの ID は、Apple の文書には 6.9 インチの `IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` しか無く、ほかは参照データ（`GET /v1/appAssetLibraryRefData` の `placementProfileGroups`）にしか無い。司令塔が読むだけの確かめ（下の「確かめ方」）で値を読み、分かった値を LEARNINGS.md とこの文書に書く。配信中の版にあって `artifacts` に無い配置グループは、今までどおり記録の `skipped` に配置グループの値のまま出るので、その値で足せる
- template 系の 16 件は同じ形なので、`workflow` と `artifacts` は同じ値になる見込み（違うのは `languages` と `baseLocale`）

## 撮影の起動と見張り

### 起動

- release ブランチを作った後のスクショの段取り（`ReleaseWatch.prepareScreenshots`）で、`capture` が `actions` なら起動する
- 先に記録に撮り始めた印（`screenshots.state` が `capturing`、`commit` は release ブランチの先頭、`run.dispatchedAt`）を書いてから、`POST /repos/{owner}/{repo}/actions/workflows/{workflow}/dispatches` を送る
  - `ref` は `release/<版>`、`inputs` は `upload: false` と `display_types`（`artifacts` の値をカンマでつないだもの）。撮り直しのときは `languages` も送る
  - `return_run_details: true` を付け、200 の応答の `workflow_run_id`・`html_url` を記録の `run` に書く（2026-02-19 から。[GitHub の告知](https://github.blog/changelog/2026-02-19-workflow-dispatch-api-now-returns-run-ids/)）
- 送った後に司令塔が落ちて run の id を書けなかったときは、次の周で `GET /repos/{owner}/{repo}/actions/workflows/{workflow}/runs?branch=release/<版>&event=workflow_dispatch` から、`dispatchedAt` より後に作られ、`actor` がトークンのアカウントの run を探して使う。5 分たっても見つからなければ送り直す（二重に送らない）
- 断られたとき: ワークフローが無い（404。barless-ios・kawarin-apple は今これ）・入力が合わない（422）は、人が直す問題にして `failed` にする（理由に「ワークフローが GitHub に無い」など）。上限（403 / 429）と 5xx は、次の周でやり直す
- 使うトークンは、司令塔の持ち主ごとのトークン。権限の Actions（読み書き）は、揺らいだ CI の流し直しのためにもう付けてある（[security.md](security.md)）。ワークフローのファイルは書かないので Workflows は要らない

### 見張り

- リリースの見回り（生きている印の 10 分ごとと、人の意図を受け付けたとき）で、`capturing` の記録の run を `GET /repos/{owner}/{repo}/actions/runs/{id}` で読む。前に読んでから 5 分たっていなければ読まない
- 記録に書くのは、run の状態（`queued` → `in_progress` → `completed`）が変わったときだけ（書き込みの予算のため）
- 終わった（`completed`）ら、`conclusion` で分ける
  - `success`・`failure`: 取り込む。`failure` でも、撮れた表示サイズの artifact は残る（template のワークフローは撮影のジョブが失敗しても `if: always()` で artifact を上げる）ので、取り込める表示サイズだけ取り込み、ほかは `skipped` に「撮影のジョブが失敗した」と run の URL を書く
  - `cancelled`（`concurrency` で後の実行に取り消された・人が取り消した）・`timed_out`: `failed` にして、撮り直せるようにする
- 起動から 6 時間たっても終わらなければ、run を取り消し（`POST …/runs/{id}/cancel`）、`failed` にする。template のワークフローは表示サイズを 1 本ずつ撮るので、実績は失敗なしで 29〜66 分、各ジョブの上限は 90 分（app-kit の v1.1.1 からは並行して撮れる。下の「撮影の並行」）

## 取り込みと比べ方

- `GET /repos/{owner}/{repo}/actions/runs/{id}/artifacts` で一覧を読み、`artifacts` の値ごとに `screenshots-<表示サイズ>` を落とす（`GET …/actions/artifacts/{id}/zip`）
- 中身は `<言語>/<ファイル名>.png`。ファイル名の順（template は `01_home.png` のように撮る順の番号が付く）を App Store の並び順にし、拡張子を除いた名前を記録の `name` にする
- 比べ方は今のまま（配信中の版の配置の画像と、AskHub が上げた画像は MD5、ほかは画素で比べる）。ただし Actions は 1 回の実行ですべての言語を撮るので、#1181 の「基準の言語に差が無ければ、文言の変わった言語だけ撮る」は使わず、すべての言語を比べる（`uiTest` は今のまま）
- 上げる前に、画像の寸法が配置グループの受け付ける寸法かを、参照データで確かめる（`placementTypes` の `specMappings` で配置グループから画像の仕様を引き、`imageSpecs` の `dimensions` と比べる）。合わない組は `skipped` に「寸法 1290x2796 は <配置グループ> に合わない」のように書く（`artifacts` の書き間違いを、上げる前に見つける）
- 差のある画面の元の画像は、今までどおり常時オンの Mac に置く。落とした zip と、差の無い画像は、比べ終わったら消す

### 初めての版と、新しい表示サイズ

- 配信中の版が無ければ、比べる相手が無いので、撮ったものをすべて新しい画面（`changed: true`、`before` なし）にする。撮る配置グループは `artifacts` のすべて
- 配信中の版にあって、その配置グループの組が無い（はじめて iPhone Duo を撮るなど）ときも、その組はすべて新しい画面にする
- 「審査に出す」画面では、新しい画面は After だけを出す。「前のままにする」を選ぶと、その画面は置かない（今の「前回に無い位置を前のままにしたものは置かない」と同じ）

## 見本の書き方

- 1 回の撮影の見本（幅 600 の JPEG）を、Git Data API の 1 回のコミットにまとめる: `POST git/trees`（先頭の tree を元に、見本を足した tree）→ `POST git/commits` → `PATCH git/refs/heads/<ブランチ>`（早送りだけ）
- tree の項目の `content` は UTF-8 の文字しか持てないので、見本は JPEG を base64 にした文字のファイルにする（パスは `store-screenshots/<版>/<撮ったコミット>/<表示サイズ>/<言語>/<位置>.b64`）。クライアントは読んで base64 を戻す。こうすると、見本が何枚でも、内容を作る要求は 3 回で済む（blob を 1 つずつ作ると、その数だけ要求が増える）
- 1 回の要求が大きくなりすぎないよう、base64 で 8 MB ごとに tree を分け、前の tree を元に次の tree を作る（1 回増えるごとに要求が 1 回増える）
- 読んだ後にほかの書き手が書いていて早送りにならなければ、読み直してやり直す（今の `move` と同じ）
- 撮ったコミットをパスに入れるので、撮り直しても前の見本を上書きしない（クライアントが古い見本を出さない）

## App Asset Library への反映

### 先に上げておく

- 比べ終わったら、差のある画面（初めての版はすべての画面）の元の画像を、アプリのライブラリに上げる（予約 → 送る → `uploaded: true`）。処理は待たない
  - 参照名は #1185 と同じ `askhub-<ファイルの MD5>`。同じ画像は、言語・組・版をまたいで 1 回だけ上げる
  - 配置はしない。ライブラリの画像は、配置して審査に出すまで App Store に出ない
- 見回りの周で、処理を待っている画像の状態を読む（`GET /v1/appAssetLibraryImages/{id}`。前に読んでから 5 分空ける）
  - `UPLOAD_COMPLETE`: 待つ（消さない。#1185 の「処理中の画像を消して上げ直す」を直す）
  - `PREPARE_FOR_SUBMISSION` など、置ける状態: 終わり
  - `FAILED`: その画面に Apple の理由（`stateDetails`）を書き、人は「前のままにする」か撮り直しを選ぶ
  - `AWAITING_UPLOAD` のまま 1 時間たったもの（予約の後に司令塔が落ちた）: 消して上げ直す
- すべて終わったら、スクショを決着（`captured`）にする。記録の `capturing` の間に、取り込みの数（`n / m 枚`）を書き、クライアントに出す
- 取り込みが 3 時間終わらなければ、待っている画面を「取り込めなかった」にしてスクショを決着させる（その画面は前のままにするしかない。撮り直せる）。何時間も止まる日があるので、審査に出す準備をずっと止めない

### 審査に出すとき

- 置き方は今の #1185 のまま（同じ画像の配置は使い回し、余った配置を消してから足りない配置を作り、並べ直す）。画像はもう取り込み済みなので、待たない
- 承認した画像がライブラリで置ける状態でない（取り込みの後に消されたなど）ときは、上げ直し、待つ間は提出の段取りを「待っている」にして次の周でやり直す（人の問題にしない）
- 初めての版・新しい組は、配信中の版の画像が無いので、承認した画像だけを置く

### 旧 API で上げてある画像

- Apple の文書（App Asset Library への移行）には、旧 API で上げた画像が配置として読めるか・移されるかが書かれていない。移行の手順は「前に入れていた言語と表示サイズごとに配置を作る」で、上げ直す前提に読める
- template 系の反映（`Tools/upload_screenshots.py`）は旧 API なので、配信中の template 系のアプリ（prime-pick-ios・idfa-vault-ios など）は、旧 API の画像しか持たない見込み
- そこで、まず読むだけで確かめる（下の「確かめ方」の 3）。そのうえで、配置として読めなければ次のようにする（決めたことの 3）
  - 比べる相手: 配置が無い組は、旧 API（`GET /v1/appStoreVersionLocalizations/{id}/appScreenshotSets`）を読んで比べる（読むだけ。非推奨だが、廃止の時期は書かれていない）
  - 置き換え: 審査に出すとき、編集できる版のその組に旧 API の画像があれば、組ごと App Asset Library に移す。旧 API の組を消し（`DELETE /v1/appScreenshotSets/{id}`）、すべての位置に配置を作る。差の無い位置は撮った画像（比べて同じとみなしたもの）、前のままにした位置は配信中の版の画像（CDN の元の大きさの画像を落として上げる）を置く
  - 消してから置くまでの間に止まっても、やり直せば同じになる（置きたい並びは、配信中の版と撮ったものだけで決まる）

## 準備完了と撮り直し

### 準備完了

- 今のまま、`isPrepared` はスクショの決着（`captured`・`failed`・`notConfigured`）を待つ。`capturing` は、撮影の実行中・取り込み・ライブラリの処理待ちのすべてを含む
- クライアントの「スクショ」の節に、今どこか（撮影の待ち・撮影中・取り込み中・ライブラリの処理 `n / m 枚`）と、run へのリンクを出す

### 撮り直す（`retakeScreenshots`）

| `kind` | 対象 | `targetVersion` | `payload` |
| --- | --- | --- | --- |
| `retakeScreenshots` | リリースを始めた版（`{ "type": "submission", "id": "<版>" }`） | 人が見たときの準備の版（`revision`） | `displayTypes`（撮り直す配置グループ。省けばすべて）、`locales`（撮り直す App Store Connect の言語。省けばすべて） |

- 受け付けるのは、`origin` が `askhub` で、終わっていない・まだ審査に出していない（`submit` が無く、審査中でない）版だけ
- 司令塔は、今の release ブランチの先頭で撮り直す。撮っている最中なら、その run を取り消してから起動し直す
- 一部だけ撮り直したときは、ほかの組は前の結果を引き継ぐ（組ごとに撮ったコミットを持つ。見本と元の画像はそのまま使う）
- 撮った後に release ブランチが進んだら、クライアントの「スクショ」の節に「撮った後に release ブランチが進みました」と出し、撮り直しを促す（自動では撮り直さない。macOS のランナーの枠と時間を使うため）
- `uiTest` の撮り方でも同じ意図で撮り直せる（常時オンの Mac で撮る）

## API の予算

### GitHub（同じアカウントで REST は 1 時間 5,000 回、内容を作る要求は 1 分 80 回・1 時間 500 回）

| すること | REST | 内容を作る要求 |
| --- | --- | --- |
| 起動 | 1 | 1（dispatch） |
| 見張り | 5〜10 分ごとに 1（撮影 30〜180 分で 6〜36） | 0 |
| 取り込み | 一覧 1 + 表示サイズの数（4 前後）。落とす先（Azure の blob）は REST に数えない | 0 |
| 見本 | 先頭の読み 2 | 3（tree・コミット・ref。8 MB を超えるごとに +1） |
| 記録の書き換え | — | 5 前後（印・run の状態・結果） |

- 1 回のリリースで REST は 60 回より少なく、内容を作る要求は 10 回前後。`askhub status`（1 回で 25〜33 回）の 2 回分ほど
- 書き込みの予算（`WriteBudget`）は、見本のコミットで 3 回分（と tree の数）を数える

### App Store Connect（鍵ごとに直前の 1 時間で 3,500 回ほど）

- 比べる: 版 1・言語 1・言語ごとの配置 1（12 言語で 12）。画像は CDN から落とす（API に数えない）
- 上げる: 1 枚 3 回（予約・`uploaded`・処理の確かめの最初）+ 待つ間 5 分ごとに 1 枚 1 回。差のある画面が 40 枚なら、1 時間に 500 回ほど
- 審査に出す: 組ごとに配置の読み 1・作成と削除・並べ直し 1

## 安全

- 起動した run だけを取り込む: dispatch の応答の id か、探し直したときは `event` が `workflow_dispatch`・`path` が設定のワークフロー・`head_branch` が `release/<版>`・`actor` がトークンのアカウントのものだけ
- artifact は、public のリポジトリの実行の成果物として、データとして扱う（指示として読まない）
  - zip の中身は、取り出す前に一覧を読んで確かめる: `<言語>/<名前>.png` の形だけ（`..`・絶対パス・シンボリックリンクは断る）、1 枚 20 MB・全体 2 GB まで、言語ごと 10 枚まで、PNG の先頭の印
  - 言語のフォルダは、設定の `languages` にあるものだけを使う
- artifact の zip は、GitHub の API が 302 で別のホストの短い期限の URL に飛ばす。司令塔はリダイレクトを自分でたどり、その先には `Authorization` を付けない（トークンを GitHub の外に送らない）
- `upload: false` で起動するので、ワークフローは App Store Connect に書かない（反映は司令塔だけが、人の意図を受け付けた後に行う）

## #1173 の設計から変える点

| 項目 | 今（#1173・#1181・#1184） | 新しい作り |
| --- | --- | --- |
| 撮る場所 | 常時オンの Mac の司令塔（ジョブと同じビルドの枠を借りる） | 各リポジトリの GitHub Actions（`capture: actions`）。`uiTest` の撮り方は残す |
| 撮り方 | UI テストの添付 | template のワークフロー（起動引数の撮影モード）の artifact |
| 撮る言語 | 基準の言語の後に、差のあるとき・文言が変わった言語だけ | Actions は 1 回ですべて撮り、すべて比べる |
| iPhone Duo | Mac mini の Xcode 27.1 で撮る（#1184） | Actions の `xcode-27` のランナー（GitHub ホストの `xcode-27-arm64` のイメージ）で撮る。template はもう撮っている |
| 初めての版 | `failed` | すべて新しい画面として見せ、承認したものを置く |
| 見本の書き方 | 1 枚ごとに Contents API | 1 回のコミット（base64 の文字のファイル） |
| 取り込み | 審査に出すときに 1 枚ずつ約 2.5 分待つ。処理中の画像を消して上げ直す | 比べた後に上げておき（人が承認する前。配置はしない）、見回りの周で待つ。処理中の画像は消さない |
| 旧 API の画像 | 読まない（`failed`） | 配置として読めなければ、旧 API で読んで比べ、置き換えるときに消す |
| 撮り直し | リリースをやめて始め直す | `retakeScreenshots`（表示サイズ・言語を選べる） |
| release.md の「Mac mini では司令塔がワーカーを兼ねるので撮影をジョブにしない」 | — | Actions で撮るので、この制約は `uiTest` だけに残る |

## 決めたこと

2026-11-22 にユーザーが決めた（#1193 で確かめた）。

1. **#1185 の扱い**: #1185（App Asset Library への移行と iPhone Duo）を先に仕上げてマージし、その上に積む（同じ日にマージした）。この設計は #1185 の読み・置き方をそのまま使う
2. **App Asset Library に上げる時期**: 比べ終わったら、差のある画像をライブラリに上げておき（配置はしない）、取り込みが終わってから「準備ができました」を出す。人が押したら、置いてすぐ提出する。Apple が受け付けない画像（寸法違いなど）も、人が確かめる前に分かる。
   人が承認する前に、公開されないライブラリに画像を書くのは、release.md の「App Store Connect の書き込みは、どれも人の意図を受け付けたときだけ」の例外とし、リリースを始める意図（`startRelease`）で作る版の枠と同じ扱いにする。配置と提出は、今までどおり人が「審査に出す」を押した後だけ
   - 採らなかった案: 人が承認した画像だけを、審査に出すときに上げる（押してから Apple に出るまで、混む日は数時間かかる）
3. **旧 API で上げてある画像**: 読むだけの確かめで配置として読めなければ、旧 API を読んで比べ、審査に出すときに旧 API の組を消して App Asset Library に置き直す（上の「旧 API で上げてある画像」）。消すのは人が審査に出したときだけ
   - 採らなかった案: #1185 のまま `failed` にし、Apple が移すのを待つ

ほかの既定（同じ日にユーザーが承認した）:

- 設定の形は、上の「撮り方の設定」（`capture`・`workflow`・`artifacts` を明示する。リポジトリのファイルから推し量らない）
- 見張りは、見回りの周（10 分ごと）で 5 分以上空けて 1 回。撮影は 6 時間、取り込みは 3 時間で打ち切る
- 撮り直しは、表示サイズ・言語を選べる。release ブランチが進んでも自動では撮り直さない
- 見本は base64 の文字のファイルにし、1 回のコミットで書く
- App Asset Library に移すのはスクショだけ。クリエイティブアセット（プロダクトページのヘッダー・検索結果の素材）は、読み書きの部品（配置の種類 `placementType`）を分けておくだけにし、流れは作らない
- 最初は template 系だけを対象にする。ninjacord 系（ninjacord-ios・notti-ios・one-tone-apple）・shariverse 系（deki-roulette-ios・oshikatsu-countdown-ios）・単発（otanecho-ios・lain-tsx-ios）は後回し（ninjacord 系は artifact の形を確かめてから `actions` に、shariverse 系は `uiTest` のまま）

## PR の分け方

それぞれ独立してマージでき、マージしても次の PR まで今の動きを変えない（`capture` を設定したリポジトリが無い間は動かない）。

| PR | 中身 |
| --- | --- |
| (0) | この設計の文書（#1192） |
| (a) | 設定の `capture`・`workflow`・`artifacts`（Swift の型・スキーマ・ベクタ・protocol.md）、ワークフローの起動（`return_run_details`）と見張り、記録の `run`、LEARNINGS.md の `workflow_dispatch` の項の直し |
| (b) | artifact の取り込み（zip の確かめ）と比べ方（すべての言語・初めての版・新しい組）、見本の 1 回のコミット（`StateStore` に足す）、クライアントの base64 の見本と「新しい」の表示。#1195（(a)）・#1196 |
| (c) | App Asset Library に先に上げて見回りで待つ、審査に出すときは置くだけ、処理中の画像を消さない、画像の寸法を参照データで確かめる（(b) から移した。参照データの本当の形を、司令塔の読むだけの確かめで見てから作る）、旧 API の画像（読むだけの確かめの結果しだい）。#1197 |
| (d) | 撮り直しの意図 `retakeScreenshots`（プロトコル・司令塔・クライアント）と、release ブランチが進んだ印 |

文書（release.md・protocol.md）は、各 PR で変えた所を直す。

## 確かめ方

1. ユニットテスト: GitHub と App Store Connect は偽物（今の `FakeAppStore` と、GitHub の転送の偽物）で、起動・見張り・取り込み・比べ・上げる・置くを流す
2. GitHub の読むだけの確かめ（GET）: 16 件の撮影のワークフローがあるか（`GET …/actions/workflows/app-store-screenshots.yml`）、prime-pick-ios・idfa-vault-ios の過去の撮影の run の artifact を落とし、取り込みの部品（zip の確かめ・並び・名前）に通す（書き込みなし）
3. App Store Connect の読むだけの確かめ: 鍵は Mac mini の司令塔の Keychain にしか無く、ssh からは読めない。司令塔に「読むだけの確かめ」（参照データの配置グループ・寸法、配信中の版の配置と旧 API の組）をログに出す道具を足し、ユーザーの承認を得て司令塔を更新してから流す。prime-pick-ios・idfa-vault-ios を対象にする
4. ワークフローの起動を伴う確かめ（ユーザーの承認のうえ）: release ブランチが無いので、`allow_non_release: true`・`upload: false` で develop を撮る。司令塔の起動・見張り・取り込みの部品を、手元から本物の GitHub に向けて 1 回だけ呼ぶ（その場かぎりの確かめで、コードには残さない）。あわせて `return_run_details` の応答を確かめる
5. 通しの確かめ（ユーザーの承認のうえ）: template 系の 1 リポジトリで「リリースを始める → Actions で撮影 → 審査に出す画面で確認 → 承認したものを App Asset Library に反映」を通す。実際に反映して審査に出すかは、そのときにユーザーに確かめる

## 撮影の並行（#1233）

app-kit の撮影の再利用ワークフローは、表示サイズを 1 本ずつ撮る（`strategy.max-parallel: 1`）。12 言語のアプリでは撮影に 1.5〜2.5 時間かかり、その間「審査に出す準備」が止まる。
そこで、空いている macOS ランナーの枠があれば並行して撮る。この節はその設計。

状態: 2026-11-23 にユーザーが決め、実装し、本物で確かめた（app-kit は v1.1.0 の app-kit#14 と、呼ぶ側の直しの v1.1.1 の app-kit#18。司令塔は #1237。下の「確かめた結果」）。
**app-kit の v1.1.0 は使わない**: 呼ぶ側の撮影のワークフローが、API で起動すると「Unexpected value '1'」で落ちる（下の「確かめた結果」）。入れるのは v1.1.1 以上。

### 方針（2026-11-22〜23 にユーザーが決めた）

| 場面 | 同時に使う macOS ランナー | 撮り方 |
| --- | --- | --- |
| ふだん | 3 本 | 表示サイズごとに並行（6.9 inch・iPad 13 inch・iPhone Duo） |
| 同じ owner で、ほかのアプリの撮影が動いているとき | 1 本 | 今と同じく 1 本ずつ |
| 夜間など空いている時間 | 5 本 | 表示サイズに加えて、言語も分けて並行 |

- 反映は司令塔のまま（変えない）。撮影は Actions だけで行い、手元の Mac では撮らない
- ねらいは、開発の Build 用に枠を残しつつ、撮影が終わるまでの時間を短くすること

### 前提（確かめた事実）

- GitHub ホストの macOS ランナーの同時実行は、owner（organization・個人）ごとに 5 本（Free）。開発の Build と分け合う。再利用ワークフローのジョブは、呼んだ側の owner の枠と課金で動く
- 2026-11-08〜15 の shilokuma-inc では、macOS のジョブが始まった時点の 30%（192 回中 57 回）で、すでに 5 本が埋まっていた。待ちの主な原因は Build の量（1 週間に 1,200 回）
- `strategy.max-parallel` には式を書ける（`jobs.<id>.strategy` で `needs`・`inputs` を使える。actionlint 1.7.12 でも通る）
- `actions/upload-artifact/merge`（複数の artifact を 1 つにまとめ直す）は、app-kit が固定している upload-artifact v7.0.2（`cf430e0`）にある
- 撮影の所要時間（2026-11-21 の idfa-vault-ios の CI と手元の計測）
  - 1 枚: macos-latest で約 18 秒、iPhone Duo（xcode-27 のランナー）で約 24 秒
  - 1 つの撮影のジョブの固定の時間（ビルド・Simulator の起動・待ち・後片付け）: 約 8〜10 分（試しの 1 本 shinkeisuijaku のように小さなアプリは約 3 分）
- 6.3 inch は 6.9 inch を ubuntu で縮めて作る（derive のジョブ）。macOS の枠を使わない

### 見込みの所要時間（5 画面 × 12 言語。表示サイズあたり 60 枚、固定の時間を 9 分とした）

| 撮り方 | 同時に使う macOS | 撮影が終わるまで | macOS の分 |
| --- | --- | --- | --- |
| 1 本ずつ（今） | 1 本 | 約 87 分（27 + 27 + 33） | 約 87 分 |
| 表示サイズごとに並行 | 3 本 | 約 33 分（いちばん長い iPhone Duo） | 約 87 分 |
| 5 本の枠に収めて言語も分ける（採った形） | 5 本 | 約 27 分（分けない iPad） | 約 105 分 |
| 表示サイズ × 言語 2 分割の 6 ジョブを 5 本で（採らなかった形） | 5 本 | 約 36 分（6 本目が 1 本目の後に始まる） | 約 114 分 |

- 言語を分けると、分けた数だけ固定の時間が増える（macOS の分が増える）。public のリポジトリなので請求は 0 ドル
- 6 ジョブを 5 本で回すと、6 本目が順番待ちになり、3 本で並行するより遅くなる。そこで、ジョブの数を枠の数より増やさない形にした

### app-kit の入力

再利用ワークフロー `app-store-screenshots.yml` と、呼ぶ側の `managed/.github/workflows/app-store-screenshots.yml` に、入力 `max_parallel` を 1 つ足す。足すだけなので minor（v1.1.0）。

| 入力 | 型 | 既定 | 中身 |
| --- | --- | --- | --- |
| `max_parallel` | number | `1` | 同時に使う macOS ランナーの数（1〜5。範囲の外なら plan で止める） |

- plan のジョブが matrix を作るとき、余った枠があれば言語を分ける。分けても、撮影のジョブの数は `max_parallel` を超えない（`app_store_config.py` の `display-types` に `max_parallel` を渡す）
  - 撮る表示サイズ（deriveFrom の無いもの）の数を D とする。`max_parallel` が D 以下なら分けない（ジョブは D 個のまま、撮影のジョブの `max-parallel` に `max_parallel` を渡して、同時に動くのを `max_parallel` 本までにする。1 なら今と同じく 1 本ずつ）
  - D より大きければ、余った枠（`max_parallel - D`）を、`AppStore/screenshots.json` に書いた順（入力 `display_types` の順ではない）に表示サイズへ 1 つずつ配り、配った表示サイズは言語を 2 つ（さらに配れば 3 つ…）に分ける。言語の数より多くは分けない（配りきれない枠は使わない）
  - template の `screenshots.json` は iPhone Duo・6.9 inch・iPad の順なので、5 本なら iPhone Duo と 6.9 inch を 2 つに分け、iPad は分けない
  - 言語は `languages.json` の順（入力 `languages` があれば、その言語だけを入力の順）のまま、なるべく同じ数になるよう先頭から区切る（12 言語なら 6 と 6、5 言語なら 3 と 2）
- 司令塔は「何本使ってよいか」だけを決めればよく、どの表示サイズが derive か（リポジトリの `screenshots.json` にしか無い）を知らなくてよい
- 分けない（`max_parallel` が D 以下）ときは、ジョブ・artifact とも今とまったく同じ

### 言語を分けたときの artifact

取り込みの取り決め（artifact `screenshots-<表示サイズ>`、中身は `<言語>/<名前>.png`）は変えない。

- 分けた撮影のジョブは、`screenshots-<表示サイズ>-part<n>` に上げる（中身は今と同じ `<言語>/<名前>.png`。part どうしで言語は重ならない）。ジョブの名前は `capture (iPhone 6.9 inch 1/2)` のようにする
- 分けた表示サイズごとに、ubuntu のジョブ（merge）が `actions/upload-artifact/merge` で `screenshots-<表示サイズ>-part*` を `screenshots-<表示サイズ>` にまとめ直す。part は消さない（消すと、失敗したジョブだけを流し直したときに撮れた part を失う。app-kit#14 の CodeRabbit の指摘）
  - 撮影のジョブが一部失敗しても、撮れた part だけでまとめる（今の「失敗しても撮れたぶんは残す」と同じ。`if: !cancelled()`）。どの part も無ければ merge は失敗し、その表示サイズの artifact は無い（司令塔は今どおり、その表示サイズを `skipped` にする）
  - ubuntu で数十秒。macOS の枠を使わない
- derive（6.3 inch）は、merge の後に、まとめ直した `screenshots-<6.9 inch>` を落として縮める（`needs` に merge を足す。分けないときは merge を飛ばし、今と同じく撮影の後に動く）
- 司令塔の取り込みは変えない（名前がぴったり `screenshots-<表示サイズ>` の artifact だけを落とす。残した part は名前が違うので取り込まない）

### 司令塔が数を決める仕組み

撮影のワークフローを起動するとき（`ReleaseWatch.dispatchScreenshotWorkflow`）に、`max_parallel` を決めて入力に足す。

| 順 | 条件 | `max_parallel` |
| --- | --- | --- |
| 1 | 司令塔を起動してから、まだリリースの見回りを一周していない（ほかの撮影が動いているか分からない） | 1 |
| 2 | 同じ owner のほかのリリースで、撮影の実行が動いている | 1 |
| 3 | 夜間（日本時間の 0:00〜7:00）で、同じ owner で epic のジョブが動いていない | 5 |
| 4 | ほか | 3 |

- 上から順に見て、最初に当てはまったもの。夜間でも、同じ owner でほかの撮影が動いていれば 1 本にする
- **ほかの撮影が動いている**: 状態リポジトリのリリースの記録（`submissions/<版>.json`）で、`screenshots.state` が `capturing` で、`run` があって終わっていない（`status` が `completed` でない）もの。App Asset Library の取り込み待ち（`run` が終わった後の `capturing`）と、`uiTest` の撮り方は、macOS のランナーを使わないので数えない
  - リリースの見回り（`ReleaseWatch.refreshOnce`）は、毎周すべてのリポジトリの終わっていない記録を読んでいる。その途中で、撮影の実行が動いている記録を `repo/版` ごとにメモリーに覚え、起動するときはそこから同じ owner のもの（自分を除く）を数える。GitHub の API も状態リポジトリの読み込みも増やさない
  - 覚えたものを消すのは、そのリポジトリの記録を読めて、その中に無かった（撮り終えた・やめた）ときだけ。設定や記録の一覧を読めなかったリポジトリは、分からないので前に覚えたものを残す（消すと、動いている撮影を見落として 3 本・5 本で起動してしまう）
  - 司令塔を起動し直した直後は覚えたものが無いので、一周するまでは 1 本にする（上の表の 1）
  - AskHub の外で動いている撮影（人が GitHub で起動したもの・template の古いワークフロー）は数えない。数えるには、リポジトリごとに実行の一覧を読む必要があり、API が増えるため
- **夜間**: 日本時間の 0:00〜7:00 をコードの定数で持つ（変えるときは PR）。夜でも epic の CI（子 PR の Build・最終 PR のマージの後の Upload）が動くので、同じ owner で epic のジョブが動いているときは夜間とみなさない
  - **epic のジョブが動いている**: 同じ owner のリポジトリに、`queued`・`assigned`・`running` のジョブがある（人を待つ `waitingHuman`・止めた `paused` は数えない）。司令塔の周（`CommanderLoop.cycle`）は毎周ジョブの見回り（`JobSweep`）で見張る epic のすべてのジョブを読んでいるので、その結果から owner ごとの有無を `ReleaseWatch` に渡して覚えさせる。これも API と読み込みを増やさない
  - 司令塔を起動し直してから 1 回目の周が終わるまでは分からないので、夜間とみなさない（3 本にする）
- **起動した後は変えない**: 数は起動するときに 1 回だけ決める。後からほかのアプリの撮影が始まったら、後のものが 1 本になる（先のものは 3 本・5 本のまま）。3 つのアプリが重なると、昼は最大 3 + 1 + 1 = 5 本になる。夜に 5 本で撮っている間にほかのアプリの撮影が始まると、後のもの（1 本）は GitHub のキューで待つ
- **撮り直し（`retakeScreenshots`）も同じ規則にする**。一部の表示サイズだけを撮り直すときは D が小さいので、余った枠で言語を分ける
- **入力を送ってよいリポジトリ**: `repo.json` の `appKit.version` が v1.1.0 以上（v1.1.0 は呼ぶ側が壊れていて、送っても送らなくても撮れないので、入れるのは v1.1.1 以上）で、`build.storeScreenshots.workflow` が `app-store-screenshots.yml`（app-kit の写すファイル）のときだけ `max_parallel` を送る。ほか（template の古いワークフロー・app-kit の v1.0.x・版の分からないもの）には送らず、今どおり 1 本ずつ撮る
  - `workflow_dispatch` は、呼ぶ側のワークフローに無い入力を送ると 422 で断る。版の記録がずれていて 422 になったら（人が写すファイルを戻したなど）、`max_parallel` を外して 1 回だけ送り直す（断られたときは実行が作られないので、二重にならない）
- 記録の形（プロトコル）は変えない。決めた数とわけは、司令塔のログに出す（例: 「並行 3 本で起動した（ふだん）」）
- 6 時間で打ち切る決まりは変えない

### app-kit の新しい版の届け方

- 2026-11-23 の時点で、app-kit を呼んでいるリポジトリはまだ無い（試しの 1 本の入れ替え tm-family/shinkeisuijaku-app-ios#83 は v1.0.1 で開いたまま。ほかの template 系は古いワークフローのまま）
- v1.1.1 を出したので、これからの入れ替えと、版を広げる仕組み（入れ替え済みのリポジトリ）で届く。状態リポジトリの `app-kit.json` は 2026-11-23 の時点でまだ無く、司令塔が最初に読んだときの一番新しい版（v1.1.1 以上）が入れ替えに使う版（`adoption`）になる。司令塔は v1.1.0 より前の版には `max_parallel` を送らないので、届く前に司令塔を更新しても困らない
- 試しの 1 本での確かめは、#83 のブランチから一時ブランチを切って撮影のワークフローだけを v1.1.0 にし、`allow_non_release: true`・`upload: false` で撮る（#83 そのものは変えない。確かめた後に一時ブランチを消す）。#83 を v1.1.0 に上げるかは、入れ替えを進めているセッションに任せる
- shinkeisuijaku は 1 言語（ja）× 5 画面なので、確かめられるのは表示サイズの並行だけ。言語を分ける形は、app-kit の fixture（2 言語）で確かめる（下の「確かめ方」）

### 上限

- 言語を分けるのは枠が余るときだけで、分けてもジョブの数は `max_parallel` 以下なので、分けたせいで順番待ちは起きない。1 回の実行の中で順番待ちになるのは、`max_parallel` が撮る表示サイズの数より小さいとき（1 本ずつ撮るときなど）で、残りのジョブは前のジョブが終わるのを待つ（今と同じ）
- ほかのジョブ（開発の Build・ほかのアプリの撮影）で枠が埋まっていれば、撮影のジョブは GitHub のキューで待つ。司令塔は今どおり見張るだけで、何もしない（6 時間で打ち切る）

### 決めたこと

2026-11-23 にユーザーが決めた。

| # | 決めたこと | 採らなかった案 |
| --- | --- | --- |
| 1 | app-kit の入力は `max_parallel` だけ。言語の分け方は plan が、ジョブの数を枠以下に収めるように決める | `max_parallel` と `language_shards` を司令塔が決める（夜間は 6 ジョブで 1 本が順番待ちになり、3 本の並行より遅い。司令塔はどの表示サイズが derive か知らない） |
| 2 | 言語を分けたときは part に上げ、ubuntu の merge で `screenshots-<表示サイズ>` にまとめ直す（取り込みの取り決めを変えない） | 司令塔が part を落としてまとめる（司令塔の取り込みを変える） |
| 3 | 夜間は、日本時間の 0:00〜7:00（コードの定数）で、同じ owner で epic のジョブが動いていないとき | 時間帯だけ／司令塔の設定ファイルで時間帯を持つ |
| 4 | 撮り直しも同じ規則 | いつも 1 本 |
| 5 | 本物の確かめは、#83 から一時ブランチを切って撮影のワークフローだけ v1.1.0 にして撮り比べる（#83 は変えない）。言語を分ける形は app-kit の fixture で流す | #83 を v1.1.0 に上げてから撮る／本物は後で |

### PR の分け方

| 順 | どこ | 中身 |
| --- | --- | --- |
| 0 | ask-hub-apple | この設計（#1233） |
| 1 | app-kit | 入力 `max_parallel`、plan の言語の分け方（`app_store_config.py`）と、そのテスト（self-test の tools のジョブで流す）、merge のジョブ、derive の `needs`、呼ぶ側の写すファイル、README・CHANGELOG。マージした後に v1.1.0 のタグを付ける |
| 2 | ask-hub-apple | 司令塔が数を決めて入力を渡す（撮影の実行が動いている記録を覚える・epic のジョブのある owner を覚える・夜間・送ってよいリポジトリ・422 のときの送り直し）とテスト、この文書と release.md・LEARNINGS.md の直し |

### 確かめた結果（2026-11-23）

- **言語を分ける形**（app-kit の fixture・2 言語 × 1 画面。`display_types: APP_IPHONE_61`・`max_parallel: 2`。app-kit の実行 45040756793）: plan が 6.9 inch を ja と en に分け、撮影のジョブ 2 本 → merge → derive（6.3 inch）がすべて成功した。まとめた `screenshots-APP_IPHONE_67`・`screenshots-APP_IPHONE_61` に `ja/`・`en/` がそろった。流したのは part を消していた版（part を残す直しは `delete-merged` を外しただけ）
- **v1.1.0 の不具合**: 呼ぶ側の撮影のワークフローが `max_parallel: ${{ inputs.max_parallel }}` で渡していたため、API で起動すると number の入力が文字列 `'1'` のまま渡り、再利用ワークフローの number の入力に「Unexpected value '1'」で断られた。実行はジョブを 1 つも作らずに失敗する（`max_parallel` を送らないときも既定の `'1'` で落ちる）。fixture の確かめは数を直接書いて渡していたので見つからなかった。`fromJSON(inputs.max_parallel)` にした v1.1.1 で直し、写すファイルの確かめにも足した（app-kit#17・#18）
- **試しの 1 本での撮り比べ**（tm-family/shinkeisuijaku-app-ios、5 画面 × 1 言語。#83 のブランチから切った一時ブランチで、撮影のワークフローだけを v1.1.1 相当にした。確かめた後に消した）

| `max_parallel` | 撮影が終わるまで（plan の開始から） | 撮影のジョブ（6.9 inch / iPhone Duo / iPad） | macOS の分 | 実行 |
| --- | --- | --- | --- | --- |
| 既定（送らない = 1） | 約 30.6 分 | 10.0 / 8.1 / 12.0 分（順に） | 約 30 分 | 45044706613 |
| 3 | 約 12.5 分 | 12.1 / 8.7 / 10.2 分（同時） | 約 31 分 | 45044709785 |

- 並行 3 本で、撮影が終わるまでの時間は約 40%（30.6 分 → 12.5 分）になり、macOS の分はほぼ同じ。どちらも artifact は 4 つ（6.3 inch を含む）そろった
- tm-family の枠が空いていたので、どの撮影のジョブもすぐ始まった。shilokuma-inc の fixture の確かめでは、開発の Build で枠が埋まっていて、撮影のジョブが始まるまで 10〜15 分待った（並行にしても、枠が空かなければ速くならない）
- 夜間の 5 本（言語を分ける）を 12 言語のアプリで本物で確かめるのは、12 言語のアプリが app-kit を入れてから


### 確かめ方

1. app-kit: plan の言語の分け方のテスト（`max_parallel` と表示サイズ・言語の数の組み合わせ）、actionlint、self-test
2. app-kit の fixture（2 言語 × 1 画面）で、言語を分ける形（part → merge → derive）を本物で流す（ユーザーが承認した。一時ブランチで流し、流した後に消す）
3. 司令塔: ユニットテスト（数の決め方・覚え方・送ってよいリポジトリ・422 の送り直し）
4. 試しの 1 本（ユーザーが承認した）: shinkeisuijaku の一時ブランチで、`max_parallel` 1 と 3 を撮り比べ、撮影が終わるまでの時間を比べる

## 撮影の設定の漏れを防ぐ（#1297）

2026-11-24 の tm-family/shinkeisuijaku-app-ios 1.0.0 のリリースで、`build.storeScreenshots` が無いまま「リリースを始める」を押したため、司令塔は撮影を `notConfigured` で飛ばした。
人が後から設定を書き、撮影のワークフローを手で起動したが、司令塔は自分で起動した実行しか取り込まない（上の「安全」）ので使われず、リリースが手作業になった。
この節は、設定が漏れたままリリースが進むのを防ぐ設計。

状態: 2026-11-25 にユーザーが決めた（下の「決めたこと」。どれも推奨の案）。実装は「PR の分け方」の順に進める。

### 分かったこと（2026-11-25）

develop（311b4312）と、状態リポジトリ（読むだけ）・shinkeisuijaku・template-app-ios・app-kit（v1.6.0 と、v1.7.0 の `assetsFrom` のブランチ）を読んだ。

| 見たもの | 分かったこと |
| --- | --- |
| 設定を作る仕組み | 無い。`build.storeScreenshots` は人が `configureRepository` で書くだけ。入れ替えの PR（`AppKitAdoptionPlanner`）が作るのは `.github/app-kit.json` だけ |
| リリースを始めたとき | 設定が無ければ、`ReleaseWatch.prepareScreenshots` が理由を残さずに `notConfigured` にする |
| `notConfigured` の版 | 撮り直せない。`SubmissionFile.retakeProblem` が「撮り方の設定が無い」で断り、クライアントも撮った組が無いので「撮り直す」を出さない。**後から設定を書いても、shinkeisuijaku の 1.0.0 は今のままでは撮れない** |
| `repo.json` の `appKit` | ずれの点検（`AppKitWatch.check`）は `appKit` の無いリポジトリを読まない。呼んでいる版を書くのは「準備をやり直す」（`RepositorySetupStep`）だけで、shinkeisuijaku は準備を流していない（`setup` も `null`）。shinkeisuijaku の develop は v1.2.0（`0cba55e`）を呼んでいる |
| 配置グループの id | Apple の文書にあるのは 6.9 inch の `IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE`・`MAC_PROFILE`・`IMESSAGE_IPHONE_DYNAMIC_ISLAND_LARGE_PROFILE` だけで、「参照データの id は決め打ちしない」と書かれている（Discovering asset specifications）。表示クラス（参照データの `placementProfileGroups[].displayClassId`）の値は文書にある（`IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY`・`IPHONE_DYNAMIC_ISLAND_MEDIUM_DISPLAY`・`IPHONE_DUO`・`IPAD_13_DISPLAY` など 20 個。Vision Pro・Mac の表示クラスは無い） |
| shinkeisuijaku の今の設定 | `IPAD_13_PROFILE`・`IPHONE_DUO_PROFILE` は表示クラスの名前から当てた値で、参照データで確かめていない。違っていると、審査に出すときにその組は黙って置かれない（`AppStoreSubmission.writeScreenshots` が参照データのプラットフォームで組を絞る） |
| template の `AppStore/` | `screenshots.json` の `displayTypes` は `APP_IPHONE_61`（6.3 inch。6.9 inch から縮めて作る `deriveFrom`）・`APP_IPHONE_DUO`・`APP_IPHONE_67`・`APP_IPAD_PRO_3GEN_129`。`languages.json` は `language`（artifact のフォルダ）・`storeLocale`（App Store Connect の言語）。app-kit v1.7.0 から、`assetsFrom` を書いた言語は撮らずに流用元の画像を使い、App Store Connect の言語との読み替えは司令塔の設定（`languages`）が持つ |
| 古い司令塔 | `startRelease` の知らない欄を断る（`PayloadReader` の `allowed`）。新しい欄は、送るときだけ要る形にする |

### 設定の組み立て

司令塔が、対象のリポジトリのあるコミットのファイルと、App Store Connect の参照データから組み立てる（部品は 1 つで、下の 2 か所から呼ぶ）。

| 欄 | 決め方 |
| --- | --- |
| `capture`・`workflow` | `actions`・`app-store-screenshots.yml`（app-kit の写すファイル。リポジトリのファイルからは読まない） |
| `artifacts` | `AppStore/screenshots.json` の `displayTypes` の名前ごとに、下の表の表示クラスとプラットフォームで参照データの配置グループを引く。1 つに決まらない名前は入れず、わけを残す |
| `languages` | `AppStore/languages.json` の並びの `storeLocale` → `{ "language": <assetsFrom があればその言語、無ければ language> }` |
| `baseLocale` | `languages.json` の先頭の `storeLocale` |

| `screenshots.json` の名前 | 参照データで引く配置グループ |
| --- | --- |
| `APP_IPHONE_67`（6.9 inch） | プラットフォーム `IPHONE_APP_STORE`・表示クラス `IPHONE_DYNAMIC_ISLAND_LARGE_DISPLAY` |
| `APP_IPHONE_61`（6.3 inch） | `IPHONE_APP_STORE`・`IPHONE_DYNAMIC_ISLAND_MEDIUM_DISPLAY`（決めたこと 3） |
| `APP_IPHONE_DUO` | `IPHONE_APP_STORE`・`IPHONE_DUO` |
| `APP_IPAD_PRO_3GEN_129`（iPad 13 inch） | `IPAD_APP_STORE`・`IPAD_13_DISPLAY` |
| `APP_APPLE_VISION_PRO` | `VISION_PRO_APP_STORE` の配置グループ（表示クラスが無いので、プラットフォームだけで 1 つに決まるとき。決めたこと 3） |
| ほか（`APP_DESKTOP` など） | 入れない（app-kit が撮らない） |

- 組み立てるのは、`.github/workflows/app-store-screenshots.yml` があって `.github/app-kit.json` の `unmanaged` に入っていない（app-kit の撮影を使う）とき。撮らないアプリは、mullion-macos と同じく `unmanaged` に入れる
- 作れないとき（`AppStore/` のファイルが無い・読めない・言語が App Store Connect の言語でない・配置グループが 1 つも引けない）は、わけを人が読む文で返す
- 一部の名前だけ配置グループを引けなかったときは、引けたものだけで作り、引けなかった名前とわけも返す（下の「いつ作るか」で `appKit.drift` に書く）
- 読むのは、いつも base（`build.baseBranch`。無ければ既定のブランチ）の先頭のファイル。設定はリリースをまたいで使うので、hotfix の release ブランチ（配信中の版のタグから作る。古い言語の並びのことがある）からは作らない
- 参照データは司令塔の鍵のどれかで読み（アプリによらない）、1 日メモリーに覚える。読めなければ組み立てない（次の機会にやり直す）

### いつ作るか（決めたこと 1）

**司令塔が自動で作り、人の承認は挟まない**。値はリポジトリのファイルと参照データから機械的に決まり、人は入れ替えの PR の承認と、審査に出す前の画像の確かめで見ているため。

- ずれの点検（6 時間ごと）で、`appKit` があり、ビルドの設定（`build`）があり、`build.storeScreenshots` が無く、app-kit の撮影を使うリポジトリに、base の先頭のファイルから作って書く
  - 入れ替えの PR をマージしたリポジトリも、次のずれの点検（司令塔を起動した直後と、その後 6 時間ごと）で作る。それより前にリリースを始めたら、始めたときに作る（下の「リリースを始めるとき」）。マージの直後に点検する形は、毎周すべての `repo.json` を読み直すことになるので採らない
  - 作れなければ、わけを `appKit.drift` に書く（クライアントの「ずれ」と「あなたの番」の「時間のあるときに」に出る）
- 人が書いた設定は書き換えない。ただし、`capture: actions` の `artifacts` の配置グループが参照データに無ければ、`appKit.drift` に書く（shinkeisuijaku の推測の値を、審査に出す前に見つける）
- 設定があってもなくても、`screenshots.json` にあるのに設定の `artifacts` に無い名前（配置グループを引けなかった・人の設定に無い）は、わけと一緒に `appKit.drift` に書く（クライアントの「ずれ」に出る。例: 「AppStore/screenshots.json の APP_IPHONE_61 が撮影の設定に無い（参照データに 6.3 inch の配置グループが無い）」）。直すのは、人が設定を直すか、組み立ての表を直す PR

### リリースを始めるとき（決めたこと 2）

**始めるシートで知らせ、既定は「設定を作って撮る」、選べば「撮らずに進む」**。

- クライアント: `build.storeScreenshots` が無いリポジトリでは（`appKit` の記録の有無によらない。手で入れ替えて、ずれの点検がまだ記録していないリポジトリもあるため）、「リリースを始める」のシートに「スクショ」の節を出す
  - 「撮影の設定がまだありません。始めると、司令塔が app-kit の撮影のワークフローと `AppStore/screenshots.json`・`languages.json` から作って撮ります（app-kit の撮影を使わないアプリは撮りません）」と、作れなかったわけ（`appKit.drift` にあれば）
  - 「撮らずに進む」を選ぶと、`startRelease` に `skipScreenshots: true` を付ける（選ばなければ送らない。古い司令塔も今どおり受け付ける）
- 司令塔: `skipScreenshots` を受け付けたら、記録を作るときにスクショを `notConfigured`（わけ「撮らずに進むを選んだ」）にしておく。スクショの段取りは決着したものを撮らないので、始めた後にずれの点検が設定を作っても、この版は撮らない（撮りたくなったら「スクショを撮る」）
- 司令塔: スクショの段取りで設定が無ければ
  - 上の組み立て（base の先頭のファイル）で作る。作れたら `build.storeScreenshots` に書いてから撮影を起動する。app-kit の撮影を使わないリポジトリは `notConfigured`（わけ「撮影の設定が無く、app-kit の撮影のワークフローも無い」）、使うのに作れなければ `failed`（わけを書く。直してから「スクショを撮る」）
  - 古いクライアントからの、選んでいない `startRelease` も同じ扱い（黙って飛ばさない）
- `notConfigured`・`failed` のわけは、記録の `screenshots.failure` に書き、クライアントの「スクショ」の節に出す

### 後から撮る（`notConfigured` の版）

- 設定がある・作れる（`build.storeScreenshots` か `appKit` がある）リポジトリでは、`notConfigured` の版でも `retakeScreenshots` を受け付ける（`retakeProblem` にリポジトリの様子を渡す）
- クライアントは、撮った組の無い版では「撮り直す」を「スクショを撮る」にして出す（表示サイズ・言語は選ばず、すべて撮る）
- 司令塔は今の撮り直しと同じく、今の release ブランチの先頭で撮る。設定が無ければ、上と同じく組み立ててから撮る
- これで、今の shinkeisuijaku 1.0.0（審査の前の `prepareForSubmission`）も、司令塔とアプリを更新した後に「スクショを撮る」で撮れる

### 呼んでいる版の記録（`appKit`）

- ずれの点検で、`appKit` が `null` のリポジトリも base の先頭を読む。`build.yml` が app-kit を呼んでいれば、呼んでいるコミットと、見つけた版ならそのタグを `appKit` に書く（`installedAt` は分からないので書かない）
  - 写すファイルがその版の中身と違えば、今のずれの点検と同じく `appKit.drift` に書く（今は、ずれの無いときしか別の版とみなさない）
  - 見つけた版に無いコミットなら、`version` を書かずに、ずれに「見つけた版に無い」と書く
  - `build.yml` の `uses:` のコミットと `app-kit-ref` が違えば、ずれに書く
- これで、手で入れ替えたリポジトリも、版を広げる相手とずれの点検に入る。読む数は、app-kit を呼ばないリポジトリでも 6 時間ごとに 3〜4 回（ブランチ・tree・中身）

### 配置グループの確かめ

- 撮った artifact を取り込むとき、`artifacts` の配置グループが参照データに無ければ、その組を取り込まずに `skipped` に「配置グループ <id> が App Store Connect に無い。build.storeScreenshots.artifacts を直す」と書く（審査に出すときに黙って落ちないように）
- 司令塔が参照データを初めて読んだとき、配置グループ（id・プラットフォーム・表示クラス）を 1 行ログに出す。司令塔を更新した後にログを読み、6.3 inch・iPad 13 inch・iPhone Duo・Vision Pro の本当の id を LEARNINGS.md とこの文書に書く

### プロトコル

| どこ | 変える所 |
| --- | --- |
| `startRelease` の `payload` | `skipScreenshots`（true だけ。撮らずに進むときだけ書く） |
| `screenshots.failure` | `notConfigured` でも書ける（わけ） |
| `retakeScreenshots` の受け付け | `notConfigured` でも、リポジトリに設定がある・作れるなら受け付ける |
| `repo.json` | 足す欄は無い（作った設定は `build.storeScreenshots`、作れないわけは `appKit.drift`） |

### PR の分け方

それぞれ独立してマージでき、司令塔の PR は司令塔を更新するまで動きを変えない。アプリの PR は、司令塔を更新してからマージする（develop へのマージで TestFlight の版が置き換わり、古い司令塔は `skipScreenshots` を断るため）。

| 順 | 中身 |
| --- | --- |
| 0 | この設計 |
| 1 | 司令塔: `appKit` が `null` のリポジトリの呼んでいる版を書く（ずれの点検）とテスト |
| 2 | プロトコル: 上の表（Swift の型・スキーマ・ベクタ・protocol.md）と、司令塔の受け付け（`skipScreenshots` で `notConfigured` にして始める・設定のあるリポジトリの `notConfigured` の版の撮り直し）。後から撮れるのは、この PR では設定（`build.storeScreenshots`）のあるリポジトリだけ（shinkeisuijaku 1.0.0 はこれで撮れる） |
| 3 | 司令塔: 設定の組み立て（参照データの表示クラス）と、ずれの点検での自動の作成・配置グループの確かめ、参照データのログ。テストは shinkeisuijaku と template の本物のファイルで |
| 4 | 司令塔: リリースを始めたとき・後から撮るときの組み立て（`appKit` があれば設定が無くても後から撮れる）・取り込むときの配置グループの確かめ |
| 5 | クライアント: 始めるシートの「スクショ」の節・「スクショを撮る」・わけの表示（スクショを PR に付ける） |

文書（この節・release.md・protocol.md・app-kit.md の「ずれの点検」・operations.md）と LEARNINGS.md は、各 PR で変えた所を直す。

### 確かめ方

1. ユニットテスト: 組み立て（shinkeisuijaku・template・askhub-create-check の `AppStore/` の本物のファイルと、参照データの偽物）、ずれの点検（`appKit` が無い・版の分かる/分からないコミット・中身のずれ・`app-kit-ref` の食い違い・設定の自動の作成）、リリースの段取り（作れる・作れない・撮らずに進む・`notConfigured` から撮る）
2. 状態リポジトリと本物のリポジトリを読むだけで、shinkeisuijaku の `appKit`（v1.2.0 と、そのずれ）と、組み立てた設定が今の手書きの設定と同じになるか（手書きに無い 6.3 inch を除く。配置グループの値は、司令塔を更新した後のログで確かめる）
3. 司令塔の更新（ユーザーの承認のうえ）の後に、ログで参照データの配置グループと、shinkeisuijaku の `appKit` が書かれたことを確かめる

### 決めたこと

2026-11-25 にユーザーが決めた。

| # | 決めたこと | 採らなかった案 |
| --- | --- | --- |
| 1 | 設定は司令塔が自動で作り、人の承認は挟まない（ずれの点検で作る。それより前にリリースを始めたら、始めたときに作る） | 案を出して人が入れる（あなたの番から `configureRepository`）／リリースを始めるときだけ作る |
| 2 | 始めるシートで知らせ、既定は作って撮る。「撮らずに進む」を選べば撮らない。選んでいない `startRelease` も作って撮る | どちらかを必ず選ぶ（司令塔も、選んでいない `startRelease` を断る） |
| 3 | 6.3 inch と visionOS も、`screenshots.json` にあれば入れる（参照データから引けなければ外して知らせる） | 6.3 inch は入れない（App Store が 6.9 inch を縮める前提）／どちらも入れない（本物の id を確かめてから足す） |
