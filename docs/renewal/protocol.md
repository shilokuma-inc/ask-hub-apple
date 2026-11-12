# プロトコル

クライアント・司令塔・ワーカー・GitHub Actions がやり取りする形を決める。
この文書は形の案で、実装では JSON Schema と、入力と出力のテスト用の例を正本にする（Swift と、後から作る Kotlin の両方のテストで同じ例を読む）。
実装した形は、リポジトリ直下の `protocol/`（`schemas/` と `vectors/`）にある。この文書の JSON の例は説明のためのもので、細部は `protocol/` を正とする。

## 置き場所の全体

| 置き場所 | 置くもの | 読むもの |
| --- | --- | --- |
| 状態リポジトリ（private。1 つ） | 機械の状態（対象のリポジトリの設定・epic・ゴール・質問の状態・ジョブ・試行・Mac の印・端末の宛先・公開鍵の記録）、すべての人の意図、依頼の添付 | クライアント・司令塔・ワーカー |
| 各リポジトリの Discussion | 依頼の要約、質問、説明、回答の写し、ゴールの写し（司令塔が書く） | 人 |
| 各リポジトリの PR | 子 PR、最終 PR、判断のカードの写し、最終 PR への指示・カードへの答え・マージの承認の写し（司令塔・ワーカーが書く） | 人・ワーカー（CI とレビュー） |

人が GitHub の画面で読めるものは各リポジトリに残し、機械が判断に使う正本は状態リポジトリに置く。両方にあるもの（質問・ゴール・判断のカード・人の意図）は、状態リポジトリが正本で、各リポジトリのものは人が読むための写しとする。

- クライアントは、人の意図をすべて状態リポジトリの `intents/` に書く。各リポジトリの Discussion・PR には書かない（段階 2 で決めた）
  - 司令塔が見張るのは状態リポジトリだけになる（ETag つきの読み取りは上限に数えられない。各リポジトリの Discussion を回らずに済む）
  - public のスレッドに、指示の入口が無くなる（誰でもコメントできる場所を、機械が読まない）
  - クライアントの書き込みが 1 か所で済む
- 各リポジトリの写しは、司令塔が書く。写しには機械の目印（`copy`）を付け、指示としては扱わない

## 状態リポジトリ

置き場所は `shilokuma-inc/askhub-state`（private）。

### ファイルの置き方

書き手ごとにファイルを分け、1 つのファイルの書き手は 1 つにする。

```
version.json                                       形の版（書き手: 人が作るときだけ）
repos/<owner>/<repo>/repo.json                     対象のリポジトリの設定（司令塔）
repos/<owner>/<repo>/icon.png                      対象のアプリのアイコン（司令塔）
repos/<owner>/<repo>/epics/<epic>/epic.json        epic の状態（司令塔）
repos/<owner>/<repo>/epics/<epic>/questions.json   質問と、その状態（司令塔）
repos/<owner>/<repo>/epics/<epic>/goal.json        ゴール（司令塔）
repos/<owner>/<repo>/epics/<epic>/decisions.json   人が決めていない判断（司令塔）
repos/<owner>/<repo>/epics/<epic>/screenshots/<commit>-<scene>.png  見える仮決めのスクショ（撮ったワーカー）
repos/<owner>/<repo>/epics/<epic>/jobs/<job>.json  ジョブ（司令塔）
repos/<owner>/<repo>/epics/<epic>/attempts/<job>/<n>.json  試行（実行した Mac のワーカー）
macs/<mac>.json                                    ワーカーの生きている印（その Mac のワーカー）
commander.json                                     司令塔の生きている印（司令塔）
notifications.json                                 進行を止めるものを知らせた記録（司令塔）
devices/<device>.json                              通知の宛先（その端末のクライアント）
keys/<seq>.json                                    公開鍵の追記の記録（クライアント。署名つき）
intents/<device>/<intent>.json                     人の意図（クライアント。署名つき）
attachments/<device>/<intent>/<n>                  依頼の添付（クライアント。<n> は 1 からの番号）
consumed/<device>/<intent>.json                    処理した人の意図の記録（司令塔）
```

- `<epic>`・`<job>`・`<intent>` は ULID（時刻の順に並ぶ一意な id）
- `<mac>` は Mac ごとに決める短い名前（英小文字・数字・ハイフン）、`<device>` は端末の公開鍵の id（下の「署名」）
- 常時オンの Mac では司令塔とワーカーが両方動くので、1 つのファイルの書き手を 1 つにするため、生きている印を `macs/<mac>.json`（ワーカー）と `commander.json`（司令塔）に分ける
- 人の意図は、リポジトリ単位の作業かどうかにかかわらず、すべて `intents/` に置く
- 依頼の添付（画像など）は `attachments/` に置く（段階 2 で決めた）。public のリポジトリに上げないので、URL を知っていても見られず、終わった epic と一緒に畳める。添付の名前・大きさ・ハッシュは依頼の封筒に入れ、署名で守る
- 終わった epic（マージ済み・やめたもの）は、マージかやめてから 30 日後に `archive/` に移し、まとめて畳む

### 共通の決まり

- どのファイルも、`"v"`（そのファイルの形の版）を持つ。知らない版のファイルは読まずに知らせる
- `v` は、欄の意味を変える・欄を消す・必須の欄を足すときに上げる。任意の欄や列挙の値を足すときは上げない。読む側は、知らない欄を読み飛ばし、知らない列挙の値を含むファイルは読めないものとして知らせる
- 型だけでは表せない決まり（数の範囲・欄どうしの関係・存在しない日付など）も、読む側で確かめる。合わないファイルは読めないものとして知らせ、書く側は合わないファイルを書かない
- 値が無い欄は、書かないか `null` にする（どちらも同じに読む）
- 時刻は UTC の ISO 8601 で、秒まで（`2026-11-03T10:00:00Z`）。小数の秒と時差の表記は使わない
- パスに使う値（リポジトリの owner/name・ULID・Mac の名前・鍵の id）は、読むときに形を確かめる。`..` や `/` を含む値で、ほかのファイルを指せないようにする（形は `protocol/schemas/common.schema.json`）
- 書き込みは Contents API で、読んだときの版（sha）を付けて行う。409（版が合わない）が返ったら読み直してやり直す
- 読み取りは `git fetch` か、ETag つきの要求で行う。Git の tree と blob（`git/trees/<sha>`・`git/blobs/<sha>`）は sha で中身が決まるので、読んだものを使い回してよい
- 空の一覧や 404 を理由に、ファイルを作り直さない（GitHub の障害で一覧が空で返ることがある）

### repo.json（対象のリポジトリ）

```json
{
  "v": 1,
  "repo": "shilokuma-inc/prime-pick-ios",
  "platform": "apple",
  "maxConcurrentEpics": 1,
  "appKit": { "ref": "<共通リポジトリのコミット>" },
  "protection": { "appliedAt": null },
  "build": {
    "baseBranch": "develop",
    "xcode": {
      "project": "PrimePick.xcodeproj",
      "scheme": "PrimePick",
      "destinations": [{ "platform": "iOS", "deviceType": "iPhone 17 Pro", "osVersion": "26.5" }],
      "testLight": { "onlyTesting": ["PrimePickTests"] },
      "testFull": { "testPlan": "Full" }
    },
    "childChecks": ["build / build"],
    "finalChecks": ["build / build", "ui-test / ui-test"],
    "trustedReviewers": ["coderabbitai[bot]"],
    "screenshots": {
      "scenes": "PrimePick/Screenshot/screenshot-scenes.json",
      "destination": { "platform": "iOS", "deviceType": "iPhone 17 Pro", "osVersion": "27.0" }
    }
  },
  "addedAt": "2026-11-03T10:00:00Z"
}
```

- `maxConcurrentEpics` は 1 以上
- `appKit` は、共通リポジトリのワークフローを入れる前は `null`
- `build` は、ビルドの設定（段階 3）。人が設定を入れる意図（`configureRepository`）で書く（入れ方は [operations.md](operations.md) の「ビルドの設定の入れ方」）。形は `protocol/schemas/repository-build.schema.json`（Swift は `RepositoryFile.Build`）
  - `baseBranch`: 作業ブランチの元で、最終 PR の向き先。無ければ develop
  - `xcode`: ビルドとテストの設定（Swift は `AskHubProtocol` の `BuildSettings`）。`project`（`.xcodeproj` か `.xcworkspace` の、リポジトリの直下からの相対パス）・`generate`（ビルドの前にプロジェクトを作る道具。`"xcodegen"` なら、ワーカーが作業場所の直下で `xcodegen generate` を流す。無ければリポジトリにあるプロジェクトをそのまま使う）・`scheme`・`destinations`（`{ "platform": "iOS" | "visionOS", "deviceType", "osVersion" }` か `{ "platform": "macOS" }`。並べた順に流す）・`testLight`・`testFull`（`testPlan`・`onlyTesting`・`skipTesting`。無ければ全部）。`xcodebuild` の引数とパスに使うので、`-` で始まる値・制御文字・リポジトリの外を指すパスを受け付けない
  - `childChecks`: 子 PR で待つチェックの名前（REST の check run の `name`。再利用ワークフローのジョブは `build / build` の形）。1 つ以上（無いと CI を待たずにマージしてしまう）
  - `finalChecks`: 最終 PR で待つチェックの名前。1 つ以上
  - `trustedReviewers`: 指摘を Claude に渡してよいレビューの書き手（GitHub のアカウント。`coderabbitai[bot]` など）。無ければ空
  - `screenshots`: 判断のカードのスクショの撮り方（Swift は `ScreenshotSettings`）。`scenes`（撮れる画面の一覧のファイルの、リポジトリの直下からの相対パス。`.json`）と `destination`（撮る Simulator。`destinations` と同じ形で、macOS はまだ撮らない）。無ければ撮らない（[flows.md](flows.md) の「スクショ」）
- `build` が無いリポジトリでは、開始を断る
- `icon`: 対象のアプリのアイコン（Swift は `RepositoryFile.AppIcon`）。司令塔が対象のリポジトリの base（`build.baseBranch`。`build` が無ければ既定のブランチ）から取り出し、256px の PNG にして `icon.png` に置く（[architecture.md](architecture.md) の「対象のアプリのアイコン」）。まだ取り出していない・見つからないなら `null`（クライアントは頭文字を出す）
  - `source`: 取り出した元（Icon Composer の `.icon` か、Asset Catalog の `.appiconset` のフォルダ）の、リポジトリの直下からのパス
  - `sourceTree`: 元のフォルダの git の tree の sha。変わったときだけ書き出し直す
  - `image`: 書いた `icon.png` の git の blob の sha。クライアントは、これを鍵に画像を端末にしまっておく（同じ sha なら読み直さない）
  - `updatedAt`: 書いた時刻

### 撮れる画面の一覧（対象のリポジトリに置くファイル）

`build.screenshots.scenes` が指すファイル。状態リポジトリではなく、対象のリポジトリに置く（epic の中で Claude が画面を足せるように）。形は `protocol/schemas/screenshot-scenes.schema.json`（Swift は `ScreenshotScenesFile`）。

```json
{
  "v": 1,
  "scenes": [
    { "id": "final-review", "title": "最終 PR の確認（見える仮決めのカード）", "arguments": ["-demoScenario", "standard", "-demoOpen", "epic:tsundoku-search"] }
  ]
}
```

- `id` は英小文字・数字・ハイフンで 40 文字まで（状態リポジトリのファイル名にも使う）。重ねない
- `title` は何の画面・状態か（人と、画面を選ぶ Claude が読む）
- `arguments` は、その画面をデモのデータで開く起動引数（`simctl launch` でアプリに渡す。シェルは通さない）。30 個まで
- 撮った画像は public の最終 PR に載り、消せない。実データ・個人情報・トークンが写らないデモのデータの画面だけを書く

### epic.json

```json
{
  "v": 1,
  "id": "01JC…",
  "repo": "shilokuma-inc/prime-pick-ios",
  "title": "ランキングの表示を変える",
  "summary": "…",
  "discussion": 512,
  "stage": "asking",
  "mac": null,
  "branch": null,
  "finalPullRequest": null,
  "merge": null,
  "pause": null,
  "goalVersion": null,
  "origin": { "keyId": "…", "nonce": "01JC…" },
  "createdAt": "…",
  "updatedAt": "…"
}
```

- `origin` は、元になった依頼の人の意図
- `summary` は、依頼の要約（何を作るか・なぜ）。質問づくりの Claude が書く。作る前は `null`
- `mac` は、開始のときに人が選んだ Mac。ほかの Mac への引き継ぎ（`handover`）で、移す先の Mac に書き換える
- `pause` は、人が一時停止した印 `{ "since": "<受け付けた時刻>", "origin": { "keyId", "nonce" } }`（`pauseEpic` の意図）。再開（`resumeEpic`）で外す。付いている間、司令塔は epic の次のジョブを作らず、まだ動いていないジョブ（`queued`・`assigned`）を `paused` にしたままにする（動いているジョブは最後まで終わらせる）。Mac がオフラインでジョブが止まっただけのときは付けない
- `merge` は、最終 PR のマージの記録 `{ "commit": "<マージのコミット>", "approval": { "keyId", "nonce" } | null, "at": "…" }`。司令塔が `merged` にするときに書く。`approval` は人の承認（`approveMerge`）の意図で、マージの規則で自動でマージしたなら `null`。クライアントは、どの端末から承認したかによらず、これで「自動でマージした」「承認してマージした」を出し分ける
- `branch` は作業ブランチ。git のコマンドに渡しても選択肢に読まれないよう、`-` で始まる値・`..` を含む値・英数字と `._/-` 以外の文字を使わない

`stage` の値と移り変わり:

| stage | 意味 | 次 |
| --- | --- | --- |
| `drafting` | 依頼を受け、質問を作っている | `asking` |
| `asking` | 人の回答を待っている（説明待ち・ロックを含む） | `checking` |
| `checking` | 着手前の確認をしている | `asking`（追加の質問）・`awaitingSplit`（大きすぎる）・`awaitingStart` |
| `awaitingSplit` | 1 つの epic に収まらないと分かり、分けて依頼し直すか、このまま 1 つで進めるかの、人の判断を待っている | `abandoned`（分けて依頼し直す）・`checking`（このまま進める） |
| `awaitingStart` | ゴールの確認と開始を待っている | `running`・`checking`（ゴールの修正） |
| `running` | 実装している | `finalizing` |
| `finalizing` | 最終 PR の前の検証と、最終 PR の対処をしている | `reviewing`・`merged` |
| `reviewing` | 人が決めていない判断の確認とマージを待っている | `finalizing`（直してほしい）・`merged` |
| `merged` | マージされた | — |
| `abandoned` | やめた | — |

開始する前の段階（`drafting`〜`awaitingStart`）からは、人の取り下げ（`abandonEpic`）か、先に進めなくなるジョブを人がやめたとき（`giveUp`）にも `abandoned` になる

### readiness.json（最後の着手前の確認の結果）

```json
{
  "v": 1,
  "version": 3,
  "verdict": "tooLarge",
  "reason": "集計と画面と課金が 1 つの epic に収まらない",
  "split": [ { "title": "集計", "summary": "日ごとの集計を作る" }, { "title": "画面", "summary": "ランキングの画面を作る" } ],
  "round": 2,
  "checkedAt": "…"
}
```

- `verdict` は `ready`（ゴールを作った）・`moreQuestions`（追加の質問を出した）・`tooLarge`（1 つの epic に収まらない）。確かめるたびに `version` を上げる
- `split` は分け方の案で、`tooLarge` のときだけ持つ。質問の往復を使い切って決めきれないときも `tooLarge` にし、`reason` に何が決めきれないかを書く（`split` は空のこともある）
- `tooLarge` のとき、epic は `awaitingSplit` になり、人が分け方の判断（`decideSplit`）で「分けて依頼し直す」（`split`。epic は `abandoned` にし、クライアントが分け方の案ごとの依頼の下書きを出す）か「このまま 1 つで進める」（`proceed`。確かめ直してゴールを作る）を選ぶ
- `proceeding` は、「このまま 1 つで進める」を選んだか（分け方の判断を受け付けたときに、`tooLarge` の結果に付ける）、選んだ後の確認の結果か（無ければ false）。true の結果の後の確認では `tooLarge` を返さず、`proceeding` を引き継ぐ。選んだことを確認の結果に残すので、確認のジョブが答え直しで取り消されても引き継げる

### questions.json（質問とその状態）

```json
{
  "v": 1,
  "questions": [
    {
      "id": "q1",
      "version": 1,
      "title": "ランキングの単位",
      "why": "集計の仕組みと画面の両方に関わるため",
      "options": [
        { "label": "日ごと", "effect": "毎日 0 時に入れ替わる" },
        { "label": "週ごと", "effect": "月曜に入れ替わる。集計の保存が要る" }
      ],
      "recommended": "日ごと",
      "reason": "今の保存の仕組みのままで作れる",
      "caution": null,
      "dependsOn": [],
      "round": 1,
      "state": "answered",
      "comment": "DC_kwDO…",
      "explanations": [
        { "asked": { "keyId": "…", "nonce": "01JC…" }, "note": "集計の保存とは？", "text": "…", "at": "…" }
      ],
      "revision": null,
      "answer": {
        "choice": "日ごと",
        "note": "夜間はもっと長くてもよい。",
        "intent": { "keyId": "…", "nonce": "01JC…" },
        "at": "…"
      }
    }
  ]
}
```

- `state` は `locked`（依存先の回答待ち）・`revising`（依存先が決まり、見直し中）・`open`（回答を待つ）・`clarifying`（説明を作成中）・`answered`・`dropped`（見直しで要らなくなった。理由は `revision` に書き、`by` は `dependency`）
- 実装の途中の質問（[flows.md](flows.md) の「実装の途中の質問」）は、`job`（質問したジョブの id）と `task`（どのタスクか。最終 PR の直しの質問は `null`）を持つ。開始前の質問は、どちらも持たない。`round` は、その epic の最後の質問の `round` に 1 を足したもの（開始前の質問が 1 つも無ければ 2。最初の質問づくりを 1 回目と数えるため）、`dependsOn` は空
- `answered`・`dropped` を「決まった」と数える。ロックを外すのは依存先がすべて決まってからで、それ以外の質問の依存先は、いつもすべて決まっている
- `version` は質問を書き直すたびに上げる。回答の人の意図は、回答した質問の `version` を持つ。古い版への回答は受け付けず、知らせる
- `caution` は、慎重に決めてほしい理由（`{ "kind": "security", "reason": "…" }`。`kind` は `security`（トークン・認証・権限・データを外に出す）・`privacy`（個人のデータ）・`irreversible`（データの削除・移行・公開など取り消せない）・`cost`（お金がかかる））。間違えると取り返しのつかない質問にだけ付け、無ければ書かない。クライアントは、その質問を警告として出す（祝う演出をやめ、警告の帯を出す）。最終 PR の判断のカードにも同じ形を使う（段階 3）
- `round` は、何回目の質問づくりで出た質問か（最初が 1。着手前の確認で足した質問は 2 から）
- `comment` は、Discussion の質問のコメントの id（人が読むための写し。GraphQL の node id）
- `explanations` は「説明を求める」と、その説明の記録。クライアントは Discussion を読まずに、質問ごとの説明のやり取りを出せる
- `revision` は、最後に書き直したときの記録（`{ "from": 1, "reason": "…", "by": "explain" }`。`by` は `explain`（説明のついでに直した）・`dependency`（依存先が決まって見直した））。書き直したことを画面で分かるようにするため
- `answer` は受け付けた回答（`choice` は選んだ選択肢。自由記述だけなら書かない）。`intent` は元の人の意図。判断はすべて人がするので、推奨の選択肢で決めたことにする回答は無い。`recommended` は、人が選ぶときの手がかり
- 開始の前に回答を変えたときは、新しい回答で置き換え、依存する質問（間接に依存するものも）の回答を取り消して `locked` に戻す。説明を作っている問いと、見直しは取り消す。同じ選択肢と自由記述で答え直したときは、依存する質問に触れない

### goal.json

```json
{
  "v": 1,
  "version": 2,
  "summary": "…",
  "decided": [ { "question": "q1", "text": "日ごとに入れ替える" } ],
  "outOfScope": [ "…" ],
  "doneWhen": [ "…" ],
  "tasks": [
    { "id": "t1", "title": "…", "detail": "…", "dependsOn": ["h1"], "state": "pending" }
  ],
  "humanTasks": [
    {
      "id": "h1",
      "title": "App Store Connect で課金のアイテムを作る",
      "why": "…",
      "steps": ["…"],
      "links": ["…"],
      "handover": { "kind": "none" },
      "state": "pending"
    }
  ],
  "notApplied": [ "…" ],
  "comment": "DC_kwDO…"
}
```

- `notApplied` は、最後のゴールの修正で反映しなかった人の指示とその理由（決まったことを変える指示など。回答を変えて直してもらう）
- ゴールを直すたびに `version` を上げる。「開始」の人の意図は、確かめたゴールの `version` を持つ
- タスクの `state` は `pending`・`locked`（人がする作業の待ち）・`running`・`done`。`dependsOn` には、ほかのタスクと人がする作業の id を書ける
  - 司令塔が、`pending` → `running`（実装のジョブを作ったとき）→ `done`（子 PR をマージしたとき）にする（[flows.md](flows.md) の「司令塔がタスクを進める」）。人が読むゴールの中身は変えないので、`version` は上げない
- 人がする作業の `handover` は、終わったら渡すもの: `none`（「終わった」を押すだけ）・`file`（ファイルを渡す）・`secret`（GitHub の Secrets に入れる。`name` に Secrets の名前。値はどこにも残さない）。段階 3 では `none` と `file` を作り、`secret` は後で作る
- 人がする作業を終えたら、司令塔が `state` を `done` にし、`done` に `{ "intent": { "keyId", "nonce" }, "at": "…", "file": <依頼の添付と同じ形の参照> | null }` を書く。人が読むゴールの中身は変えないので、`version` は上げない
- `comment` は、Discussion のゴールの写しのコメントの id

### decisions.json（人が決めていない判断）

```json
{
  "v": 1,
  "items": [
    {
      "id": "d1",
      "task": "t2",
      "pullRequest": 41,
      "visible": true,
      "what": "見出しの文言を短くした",
      "why": "ゴールの t2（iPhone の幅に収める）",
      "alternatives": ["2 行にする"],
      "scene": "final-review",
      "screenshots": {
        "before": "repos/…/epics/<epic>/screenshots/<base との分岐点>-final-review.png",
        "after": "repos/…/epics/<epic>/screenshots/<作業ブランチの先頭>-final-review.png",
        "beforeURL": "https://github.com/user-attachments/assets/…",
        "afterURL": "https://github.com/user-attachments/assets/…",
        "head": "<作業ブランチの先頭>",
        "note": null
      },
      "answer": null
    }
  ]
}
```

- 項目は、ループの仮決め（実装の途中で Claude が決めたこと）。質問はすべて人が答えるので、質問から来る項目は無い
- `visible` は、ユーザーから見える挙動・仕様・見た目に関わるか。決めるのは、読むだけのレビュー役の Claude と、決まった信号（View・文言・アセット・Info.plist・entitlements の差分、スクショの差）
- 各項目は `task`（どのタスクの仮決めか）と `pullRequest`（子 PR）を持つ。`visible` は仕分ける前は `null`。最終 PR の直しの仮決めは `task` を持たない（`null` か省く）
- 司令塔は、実装と直しの試行の `outputs.report.decisions` を足す（id は `d1` から続ける）。同じタスク・子 PR の同じ仮決めは 2 度足さない
- `scene` は撮る画面（リポジトリの撮れる画面の一覧の `id`）。判断の仕分けの Claude が、見える仮決めごとに一覧から選ぶ。合う画面が無ければ `null`
- スクショは、撮影のジョブ（`captureScreenshots`）が epic の `screenshots/<コミット>-<画面>.png` に置き、司令塔が `screenshots` にそのパスを写す。Before は base との分岐点、After は作業ブランチの先頭のコミット。同じコミット・画面は撮り直さず、いくつかの仮決めが同じ画像を指すことがある
  - `beforeURL`・`afterURL` は GitHub に上げた同じ画像の URL（`https://github.com/user-attachments/assets/…` だけ。最終 PR の本文に載せる）。上げられなければ `null`
  - `head` は After を撮った作業ブランチの先頭、`note` は撮れなかったわけ・Before が無いわけ（人が読む。500 文字まで）
- `scene`・スクショ・`answer` は、見えると仕分けた仮決めだけが持つ
- `screens` は画面の変化（仮決めに結びつかない、epic 全体で見た目が変わった画面）。`[{ "scene": "inbox-quiet", "title": "あなたの番が空のとき", "screenshots": { …仮決めと同じ形… } }]`。
  判断の仕分けで選ぶ前（撮影の設定が無いリポジトリを含む）は省くか `null`、選んで無ければ空。`title` は撮ったときの一覧の説明で、撮る前は `null`。`scene` は重ねない
- `answer` は `{ "choice": "ok" | "alternative" | "fix", "note": "…", "intent": { "keyId", "nonce" }, "at": "…" }`（型は `DecisionsFile`、`protocol/schemas/state/decisions.schema.json`）
- `answer` は人の意図（OK・別案・直してほしい）への参照
- 最終 PR の直し（`fixFinalPullRequest`）で Claude が報告した仮決めも足す。タスクに結びつかないので、`task` は持たず（`null`）、`pullRequest` は最終 PR にする。クライアントは「最終 PR #N の直し」と出す
- 「別案にする」「直してほしい」の直しが済んだら、司令塔がその答えを外して答え待ちに戻す（直った後を見て答え直してもらう）。同じカードへの答え直しは受け付けない（[flows.md](flows.md) の「司令塔が最終 PR を進める」）

### jobs/<job>.json（ジョブ）

```json
{
  "v": 1,
  "id": "01JC…",
  "kind": "implementTask",
  "repo": "shilokuma-inc/prime-pick-ios",
  "epic": "01JC…",
  "task": "t1",
  "assignedMac": "macbook-a",
  "needs": { "claude": true, "build": true },
  "dependsOn": [],
  "state": "assigned",
  "attempts": 1,
  "nextRunAt": null,
  "input": { "question": "q2" },
  "origin": { "keyId": "…", "nonce": "01JC…" },
  "createdAt": "…",
  "updatedAt": "…"
}
```

- `input` は kind ごとの入力（下の表）。`origin` は、ジョブの元になった人の意図。ワーカーは引き受ける前に、その意図の署名を自分でも確かめる

| kind | input |
| --- | --- |
| `makeQuestions` | `{}`（依頼は epic の `origin` の意図から読む） |
| `explain` | `{ "question": "q2", "asked": { "keyId", "nonce" } }` |
| `reviseQuestion` | `{ "question": "q4" }` |
| `checkReadiness` | `{ "round": 1 }` |
| `reviseGoal` | `{ "instruction": { "keyId", "nonce" } }` |
| `prepareWorkspace` | `{}`（作業ブランチは `epic.json` の `branch`。無ければ作って書く） |
| `implementTask` | `{}`（タスクはジョブの `task`）。実装の途中の質問の答えで再開するときは `{ "question": "q5" }` |
| `reviewTask` | `{ "pullRequest": 41, "head": "<コミット>" }`（実装・直しの試行の `outputs.pullRequest` と、push した head の `outputs.commit`） |
| `fixTask` | `{ "pullRequest": 41, "head": "<コミット>", "reason": "ci" }`（`reason` は `ci`・`review`。`head` は判定を出したレビューの input の head。直しの回は試行から数える）。実装の途中の質問の答えで再開するときは、元の input に `"question": "q5"` を足す（`fixFinalPullRequest` も同じ） |
| `rerunChecks` | `{ "pullRequest": 41, "head": "<コミット>", "runs": [123] }` |
| `integrateDevelop` | `{ "base": "<取り込む base のコミット>" }` |
| `verifyBeforeFinal`・`classifyDecisions`・`openFinalPullRequest`・`cleanUp` | `{}` |
| `captureScreenshots`・`reviewFinalPullRequest`・`mergeFinalPullRequest` | `{ "pullRequest": 512, "head": "<コミット>" }`（撮影は、続けてレビューする最終 PR と head） |
| `fixFinalPullRequest` | `{ "pullRequest": 512, "head": "<コミット>", "reason": "ci" }`（`reason` は `ci`・`review`・`human`・`conflict`。`human` は判断のカードの「直してほしい」「別案にする」と `instructFinal` で、元の人の意図はジョブの `origin`。`conflict` は、ワーカーが base を作業ブランチに取り込み、コンフリクトしたファイルを Claude に解消させる） |
| `notify` | 段階 4 で決める |

- タスクのジョブ（`implementTask`・`reviewTask`・`fixTask`）は、司令塔が元のジョブの結果から作り、`task` にタスクの id、`dependsOn` に元のジョブ（`implementTask` は作業場所の用意）を書く。同じタスクの直しが 3 回を超えたら、`fixTask` を `waitingHuman` で作る（試行の前なので `attempts` は 0。[flows.md](flows.md) の「司令塔がタスクを進める」）。最終 PR の直し（`fixFinalPullRequest`）も同じ。
  上限の回数は Swift の `FixTaskInput.maxAutomaticRounds` で、司令塔とクライアントが同じ値を使う。クライアントは、試行の無い（`attempts` が 0 の）人の対応待ちの直しを、上限を超えて止めたものとして、直す理由（`reason`）の区分（`ci` はビルド・テスト、`review` はレビューの指摘、`conflict` はコンフリクト）と止めた理由の文で「対処が要ります」に出す
- `kind` の最初の一覧: `makeQuestions`・`explain`・`reviseQuestion`・`checkReadiness`・`reviseGoal`・`prepareWorkspace`・`implementTask`・`reviewTask`・`fixTask`・`integrateDevelop`・`verifyBeforeFinal`・`openFinalPullRequest`・`reviewFinalPullRequest`・`fixFinalPullRequest`・`rerunChecks`・`classifyDecisions`・`captureScreenshots`・`mergeFinalPullRequest`・`cleanUp`・`notify`
- `state` は `queued`・`assigned`・`running`・`succeeded`・`failed`・`waitingHuman`・`paused`・`canceled`
- ジョブのファイルは司令塔だけが書く。ワーカーは、自分の試行のファイルに「始めた」を書くことで、ジョブを引き受けたことを示す。司令塔は試行を読んでジョブの `state` を更新する
- `paused` には 2 つの止め方がある。ジョブに印は足さず、当てた試行（番号が `attempts` のもの）で分ける（Swift は `JobFile.isWaitingForOfflineMac`。クライアントも同じ決まりで出し分ける）
  - Mac がオフラインで止まったジョブ: 当てた試行が、担当の Mac（`assignedMac`）で実行中のまま止まったか、`macOffline` で失敗したもの。同じ Mac が戻ったら続きから動かす
  - 人の一時停止（`epic.json` の `pause`）で止めたジョブ: それ以外。一時停止の間は、前の試行の失敗で決め直さない（人の「やり直す」で戻したジョブを、人の対応待ちに戻さない）。再開で `assigned` に戻す（待ちの時刻は止めたときのまま）
- 引き継いだ epic では、epic の Mac で動くジョブ（作業場所の用意・タスクのジョブ・`integrateDevelop`・検証・撮影・片付け、epic の Mac に割り当てた最終 PR の直し）のうち、動いていないもの（`queued`・`assigned`・`paused`・`waitingHuman`）を、司令塔が epic の今の Mac に付け替える。前の Mac がオフラインで止まったまま（実行中の試行が残った）のジョブは、前の Mac を待たずに `assigned` に戻し、移す先が次の番号の試行で、作業ブランチ（最後に push したところ）から続ける。一時停止中に前の Mac で動き続けたジョブも、終わった後にやり直すときは移す先に付け替える

#### ジョブの引き受けと試行の段取り

| 誰が | すること |
| --- | --- |
| 司令塔 | ジョブを `assigned` にし、担当の Mac（`assignedMac`）を決める |
| ワーカー | 自分宛ての `assigned` のジョブのうち、`nextRunAt` を過ぎ、`dependsOn` がすべて成功したものを、Mac ごとの同時の上限（Claude・ビルド）の範囲で引き受ける。引き受けるときは `attempts + 1` 番の試行を「実行中」で作る（版なしで作るので、同じ番号の試行は 2 つできない） |
| ワーカー | 実行中は 5 分ごとに試行の `heartbeatAt` を書き、終わったら結果を書く。書き込みの予算・GitHub の上限に当たったら、待って書き直す（合わせて 2 時間まで。終えた試行の結果を捨てない）。終わった試行は書き換えない |
| 司令塔 | 試行を読んでジョブを更新する。当てた試行の番号を `attempts` に持ち、同じ試行の結果を 2 度当てない |

- 引き受ける順は、人が待っているジョブ（説明・質問やゴールの見直し・通知）→ 質問づくり・着手前の確認 → 最終 PR の対処 → 実装 → 片付け
- どの試行でも成功が書かれたら、ジョブは成功にする（時間切れとみなして試し直しにした後や、人に渡した後に、元のワーカーが成功を書いたときも、同じ作業をもう一度流さない）
- 実行中の試行の `heartbeatAt` が 15 分より古いときは、その Mac の生きている印（`seenAt`）が 30 分より古ければ「Mac がオフライン」（一時停止）、新しければ「時間切れ」として扱う。オフラインで止めたジョブは、同じ Mac が戻って試行の印が新しくなれば再開する
- 失敗の後の扱い（`architecture.md` の表の細部）:
  - ランナー不足: 10 分から倍にして最大 60 分待ち、回数の上限なしで試し直す
  - 揺らぎ: 1 回だけ流し直す。2 回目からはテストの失敗として直させる
  - ビルド・テストの失敗、レビューの必須の指摘、コンフリクト: Claude に 3 回まで直させ、4 回目で人へ。待つだけの失敗（ランナー不足など）は回数に数えない
  - 利用上限: 試行の `failure.retryAt`（分からなければ 1 時間後）まで待つ
  - GitHub の障害: 1・2・5・10・30 分と待ちを延ばして試し直す
  - 時間切れ: 1 回は試し直し、続けて時間切れなら人へ
  - 認証切れ・想定外: すぐ人へ

### attempts/<job>/<n>.json（試行）

```json
{
  "v": 1,
  "job": "01JC…",
  "n": 1,
  "mac": "macbook-a",
  "startedAt": "…",
  "heartbeatAt": "…",
  "endedAt": null,
  "outcome": "running",
  "failure": null,
  "outputs": { "pullRequest": 840, "commit": "…" },
  "claude": { "model": "claude-opus-5-5", "session": "…", "estimatedCostUsd": 0.42 }
}
```

- `outcome` は `running`・`succeeded`・`failed`
- `outputs` は外部の id（`pullRequest`・`commit`・`branch`）と、司令塔が次のジョブを決めるのに読む結果。外部の id は、やり直す前に、すでにできているかを確かめるのに使う
  - `verdict`: 子 PR のレビュー（`reviewTask`）と最終 PR のレビュー（`reviewFinalPullRequest`）の判定。`merged`（子 PR をマージした）・`ready`（最終 PR が通った。マージは規則と人の承認で決める）・`fixCI`（CI が落ちた）・`fixReview`（必須の指摘）・`fixConflict`（最終 PR が base とコンフリクトしている。最終 PR だけ）。直す判定のときは `findings` を持つ
  - `mergeRisks`: 最終 PR のレビューが見つけた、手動のマージの条件に当たるもの（`security`・`weakenedTests`・`dataMigration`・`sensitivePaths` と理由）。司令塔がマージの規則に当てる。`ready` のときは必ず書く（無ければ空）。`sensitivePaths` は、レビュー役の Claude のほかに、差分のパスの決まった規則（`.github/`・`.claude/`・`.mcp.json`・ビルドのスクリプト・依存・entitlements・Info.plist・`.xcconfig` など）でも足す
  - 最終 PR のレビューの間に head が進んだときは、`verdict` を書かずに成功で終え、`commit` に今の head を書く（古い head の判定は書かない）
  - `visibleDecisions`: 判断の仕分け（`classifyDecisions`）で見えるとした仮決めの id。ここに無いものは内部の細部。司令塔が `decisions.json` の `visible` に写す
  - `decisionScenes`: 判断の仕分けで、見えるとした仮決めごとに選んだ撮る画面（仮決めの id → 撮れる画面の一覧の id）。合う画面が無い仮決めは載せない。司令塔が `decisions.json` の `scene` に写す
  - `screenshots`: 撮影（`captureScreenshots`）で撮った、仮決めごとの Before / After（`decisions.json` の `screenshots` と同じ形）。司令塔が `decisions.json` に写す
  - `changedScenes`: 判断の仕分けで選んだ、epic 全体で見た目が変わった画面（撮れる画面の一覧の id。無ければ空）。撮影の設定があり、画面の変化をまだ選んでいないときだけ書く。司令塔が `decisions.json` の `screens` に写す
  - `screenChanges`: 撮影で撮った、画面の変化の Before / After（`decisions.json` の `screens` と同じ形）。司令塔が `decisions.json` に写す
  - `findings`: 直すこと（落ちたチェックとログの抜粋・必須の指摘）。20,000 文字まで。トークンらしい文字列は伏せてから書く
  - `report`: 実装と直し（`implementTask`・`fixTask`）で Claude が報告したこと（`summary`・`decisions`・`learnings`・`question`）。司令塔が `decisions.json`・知見を足す PR・質問に写す
- `branch` は作ったブランチで、作業場所の用意（`prepareWorkspace`）なら作業ブランチ（`epic.json` の `branch` と同じ形。`epic.json` には司令塔がこれを読んで書く）
- `failure` は `{ "class": "…", "message": "…", "logExcerpt": "…", "retryAt": "…" }`。ログの抜粋は、トークンらしい文字列を伏せてから書く。`retryAt` は再開してよい時刻（利用上限の解除の時刻など）
- 欄どうしの決まり: `running` のときは `endedAt` を書かず、終わったら必ず書く。`failure` は `failed` のときだけ書く。`heartbeatAt` と `endedAt` は `startedAt` より前にならない
- 失敗の区分（`class`）: `runnerUnavailable`・`flaky`・`buildFailed`・`testFailed`・`reviewRequired`・`conflict`・`usageLimit`・`authExpired`・`githubOutage`・`claudeOutage`・`macOffline`・`timeout`・`unexpected`（扱いは [architecture.md](architecture.md) の表）
- `heartbeatAt` は、長い試行の途中で一定の間隔で書く。古いまま止まった試行は、司令塔が `macOffline` か `timeout` として扱う

### macs/<mac>.json（ワーカーの生きている印）

```json
{
  "v": 1,
  "mac": "macbook-a",
  "kind": "resident",
  "seenAt": "…",
  "versions": { "worker": "0.2.0-3-gabc1234", "compatibility": 1, "claude": "2.1.316", "xcode": "27.1" },
  "diskFreeGB": 120,
  "load": 3.2,
  "capacity": { "claude": 2, "build": 1 },
  "selfCheck": {
    "checkedAt": "…",
    "keychain": "ok",
    "githubToken": "ok",
    "claudeToken": "ok",
    "githubTokenExpiresAt": "…",
    "claudeTokenExpiresAt": "…",
    "githubTokens": [
      { "owner": "shilokuma-inc", "state": "ok", "expiresAt": "…", "rateLimit": { "limit": 5000, "remaining": 4210, "resetAt": "…" } },
      { "owner": "mrs1669", "state": "ok" }
    ]
  },
  "refusal": { "reason": "incompatible", "message": "司令塔の互換の番号は 2、このワーカーは 1。ワーカーを更新するまで新しいジョブを引き受けない" }
}
```

- `kind` は `alwaysOn`・`resident`・`manual`
- `versions.worker` は実行ファイルに埋め込んだ版（`git describe --tags --match 'machine-v*'` から作る。タグそのものなら `0.2.0`、その後のコミットなら `0.2.0-3-gabc1234`。埋め込んでいないビルドは `0.0.0-dev`）。`versions.compatibility` は互換の番号（整数）。照らし合わせ方は下に書く。合わないときの更新の手順は [operations.md](operations.md) の「司令塔の更新」「ワーカーの入れ方（段階 3）」（差し替えて読み込み直す）
  - 互換の番号は、司令塔とワーカーの間の決まり（ジョブの種類・入力と出力・試行の書き方・状態のファイルの形）を変えたときだけ上げる（`MachineCompatibility.current`）
  - ワーカーは、司令塔（`commander.json`）の `versions.compatibility` と自分の番号が合わないとき・`commander.json` を読めない（知らない版・形の違うもの）ときは、新しいジョブを引き受けず、`refusal` に理由を書く。動かしているジョブは手放さない。番号を書かない司令塔（前の版）・`commander.json` が無いときは照らし合わせない
  - 起動してから `commander.json` を一度も読めていない（GitHub に届かないなど）間は、新しいジョブを引き受けない。一度読めた後に読めなくなったときは、前の判断のまま続ける
  - クライアントは、互換の番号が司令塔と合わない Mac（または `refusal` が `incompatible` の Mac）を Mac の画面と「あなたの番」に出し、更新の手順を添える。番号を比べられない（ワーカーが `commander.json` を読めない）ときは、どちらを更新するかを決めずに、ワーカーが書いた理由を出す。版が違うだけ（互換の番号は同じ）なら、Mac の詳細に出すだけにする
- `refusal` は、新しいジョブを引き受けていないときだけ書く。`reason` は `incompatible`（司令塔と互換の番号が合わない・`commander.json` を読めない）、`message` は人が読む説明
- `versions.claude` は、印を書くたびに測る `claude --version`。クライアントは、司令塔（`commander.json`）と違う Mac を知らせる
- `selfCheck` は印を書くたびに確かめる。各項目は `ok`・`missing`・`invalid`・`expired`。トークンの値そのものは書かない
  - `githubTokens` は、持ち主（organization・個人。小文字にそろえる）ごとの GitHub のトークンの様子と期限。持ち主は重ねない
  - `githubToken` は持ち主ごとの様子をまとめたもの（1 つでも無ければ `missing`、次に `invalid`・`expired` の順）。`githubTokenExpiresAt` は持ち主ごとの期限のうち一番早いもの
  - トークンの期限は、分かるときだけ書く。GitHub のトークンは GitHub の API の応答の見出し `github-authentication-token-expiration` で分かったもの（期限の無いトークンには書かない）、setup-token は入れた日から 1 年（入れた日が分からなければ書かない）。読み方と知らせ方は [operations.md](operations.md) の「トークンの期限」
  - `githubTokens[].rateLimit` は、そのトークンで読んだ GitHub の REST の一次の上限（`GET /rate_limit` の `resources.core`）。`limit`（1 時間の上限）・`remaining`（今の窓の残り）・`resetAt`（窓が終わって `limit` に戻る時刻）。読めなかった（使えないトークン・GitHub の障害）ときは書かない。上限はアカウントごとに数えるので、同じアカウントのトークンはほぼ同じ値になる。クライアントは一番少ないものを出す（[operations.md](operations.md) の「GitHub の上限」）
- 変化があったときと、一定の間隔（10 分程度）でだけ書く

### commander.json（司令塔の生きている印）

```json
{
  "v": 1,
  "mac": "mac-mini",
  "seenAt": "…",
  "versions": { "commander": "0.2.0-3-gabc1234", "compatibility": 1, "claude": "2.1.316" },
  "selfCheck": { "checkedAt": "…", "keychain": "ok", "githubToken": "ok", "claudeToken": "ok" }
}
```

- `versions` と `selfCheck` の書き方は `macs/<mac>.json` と同じ（同じ周に、同じ様子を書く）

- GitHub Actions の見張りが、`seenAt` の古さ（30 分。`macs/<mac>.json` のオフラインの判定と同じ）を確かめる。無い・読めないときも止まったとみなす（[operations.md](operations.md) の「司令塔の見張り」）

### devices/<device>.json（通知の宛先）

```json
{
  "v": 1,
  "device": "<鍵の id>",
  "platform": "ios",
  "push": { "service": "apns", "token": "<16 進>", "environment": "production" },
  "updatedAt": "…"
}
```

- `push.environment` は APNs の送り先の環境。開発用の署名の版（Xcode から入れた版）は `development`、TestFlight と App Store の版は `production`。APNs の宛先では必ず書く
  - クライアントは、ビルドの構成ではなく署名から決めた値を書く（iOS の実機は埋め込みの provisioning profile の `aps-environment`、profile が無ければ `production`。macOS は署名の entitlement。[operations.md](operations.md) の「通知」）
  - 司令塔は、`400 BadDeviceToken` で断られたら、もう一方の環境に 1 回だけ送る（環境を取り違えて書いた古い版のアプリのため）
- クライアントは、トークン・環境・端末の種類のどれかが変わったときだけ書き直す（起動のたびに書かない）
- `push.token` は送るときに URL のパスに入るので、16 進だけを受け付ける
- Android を足すときに、`platform` と `push.service`（FCM）を足す
- 司令塔は、ファイルの名前と `device` が合い、確かめた公開鍵の一覧にある（登録済みで取り消していない）端末にだけ送る

### notifications.json（進行を止めるものを知らせた記録）

```json
{
  "v": 1,
  "sent": [
    { "key": "question/shilokuma-inc/prime-pick-ios/01JC…/q2/1/0", "at": "2026-11-03T10:00:00Z" },
    { "key": "mac/macbook-a/2026-11-03T09:00:00Z", "at": "2026-11-03T10:00:00Z" }
  ]
}
```

- 司令塔は、知らせる前に出来事の `key` を足す。記録にある出来事は送らない（[operations.md](operations.md) の「通知」）
- `key` は出来事ごとに決まる。同じ質問でも、版や説明の数が変われば別の出来事になる

  | 出来事 | key |
  | --- | --- |
  | 質問が回答を待っている | `question/<owner>/<repo>/<epic>/<質問の id>/<版>/<説明の数>` |
  | 分け方の判断を待っている | `split/<owner>/<repo>/<epic>/<readiness.json の version>` |
  | ゴールの確認と開始を待っている | `start/<owner>/<repo>/<epic>/<goal.json の version>` |
  | 最終 PR の確認とマージの承認を待っている | `review/<owner>/<repo>/<epic>/<最後のレビューが見た head>/<最後のレビューのジョブ>` |
  | ジョブが人の判断を待っている | `job/<owner>/<repo>/<epic>/<job>/<attempts>` |
  | ジョブを持った Mac が戻らない | `mac/<mac>/<その Mac の seenAt>` |

- どの端末にも送れなかった出来事は、記録から外して送り直す。終わった出来事の記録は、7 日たってから消す
- 通知の中身の `askhub` は、クライアントが通知から開く先（epic の出来事は `{"repo": "<owner/repo>", "epic": "<epic>"}`、Mac は `{"mac": "<mac>"}`）。APNs の `thread-id` は epic の id か `mac/<mac>`、`apns-collapse-id` はまとめた出来事の key から決める

## 各リポジトリに書く目印

HTML のコメントの形で、本文の末尾に置く。1 つのコメントに 1 つだけ。書式は 1 つにそろえる。

```
<!-- askhub v1 {"type":"…", …} -->
```

- `type` は、機械が書くもの（`request`・`question`・`explanation`・`goal`・`closing`・`decisions`・`status`・`finalPullRequest`・`copy` など）
- 各リポジトリの目印は、表示と照らし合わせのためだけに使い、指示としては扱わない。人の意図は状態リポジトリの `intents/` にだけ置く
- `copy` は、人の意図の写し（`{"type":"copy","kind":"answer","intent":"<nonce>"}`）。司令塔が、処理した人の意図の中身を人が読める形で書く
- 引用の中の目印は読まない（目印は、コメントの本文の最後の行でなければならない）
- 目印は、自分（トークンのアカウント）が書いたものだけを読む（GraphQL の `viewerDidAuthor`）。public のリポジトリでは、誰でも目印をまねたコメントを書けるため
- Discussion の写し（段階 2。書き方は [flows.md](flows.md) の「Discussion の写し」）の目印は、どれも `epic`（epic の id）を持つ

  | 写し | 目印 |
  | --- | --- |
  | 依頼（Discussion の本文） | `{"type":"request","epic":"…"}` |
  | 質問（コメント） | `{"type":"question","epic":"…","question":"q1"}` |
  | 説明（質問のコメントへの返信） | `{"type":"explanation","epic":"…","question":"q1","intent":"<説明を求めた人の意図の nonce>"}` |
  | 回答（質問のコメントへの返信） | `{"type":"copy","kind":"answer","epic":"…","question":"q1","intent":"<回答の人の意図の nonce>"}` |
  | ゴール（コメント） | `{"type":"goal","epic":"…"}` |
  | 締め（コメント。マージした・やめた epic） | `{"type":"closing","epic":"…"}` |

## 人の意図と署名

### 封筒

人の意図は、次の封筒（envelope）に入れて署名する。

```json
{
  "v": 1,
  "kind": "answer",
  "repo": "shilokuma-inc/prime-pick-ios",
  "target": { "type": "question", "epic": "01JC…", "id": "q1" },
  "targetVersion": "1",
  "bodySha256": "…",
  "payload": { "mode": "answer", "choice": "日ごと", "note": "" },
  "issuedAt": "2026-11-03T10:00:00Z",
  "nonce": "01JC…",
  "keyId": "…"
}
```

| kind | target | targetVersion | payload |
| --- | --- | --- | --- |
| `request` | リポジトリ | — | `title`、`body`、`attachments`（`[{ "n": 1, "name": "…", "size": …, "sha256": "…" }]`。中身は `attachments/<device>/<intent>/<n>` に、意図より先に置く。`n` は 1 から順に、10 個・1 つ 50 MiB まで）（`payloads/request.schema.json`） |
| `answer` | 質問 | 質問の `version` | `mode`（`answer`・`clarify`）、`choice`、`note`（`protocol/schemas/payloads/answer.schema.json`） |
| `startEpic` | epic | ゴールの `version` | `mac`（`payloads/startEpic.schema.json`） |
| `reviseGoal` | epic | ゴールの `version` | `instruction`（指示の本文。`payloads/reviseGoal.schema.json`） |
| `decideSplit` | epic | 着手前の確認の結果（`readiness.json`）の `version` | `choice`（`split`・`proceed`。`payloads/decideSplit.schema.json`） |
| `decision` | 判断のカード（`{ "type": "decision", "epic", "id": "d1" }`） | 最終 PR の head のコミット | `answer`（`ok`・`alternative`・`fix`）、`note`（別案・直してほしいときの本文） |
| `approveMerge` | 最終 PR（`{ "type": "finalPullRequest", "epic" }`） | 最終 PR の head のコミット | —（見える仮決めにすべて答えた後でだけ受け付ける） |
| `instructFinal` | 最終 PR（`{ "type": "finalPullRequest", "epic" }`） | 最終 PR の head のコミット | `instruction`（指示の本文） |
| `humanTaskDone` | 人がする作業（`{ "type": "humanTask", "epic", "id": "h1" }`） | ゴールの `version` | `none` は空、`file` は `attachments`（1 件。依頼の添付と同じ形・置き場所・上限） |
| `pauseEpic`・`resumeEpic` | epic | —（epic の今の状態に対してだけ意味を持つ） | 空（`payloads/pauseEpic.schema.json`・`payloads/resumeEpic.schema.json`）。開始した後の epic（`running`・`finalizing`・`reviewing`）だけ一時停止できる。止めている epic の一時停止と、止めていない epic の再開は、何もせずに受け付ける |
| `handover` | epic | —（同上） | `mac`（移す先の Mac。オフラインでもよい。`payloads/handover.schema.json`）。開始した後の epic で、一時停止中か、epic の Mac で動いている（`running` の）ジョブが無いときだけ受け付ける。登録されていない Mac（`macs/<mac>.json` が無い）は断る |
| `abandonEpic` | epic | —（どの段階でも取り下げの意味は変わらない） | 空（`payloads/abandonEpic.schema.json`）。開始する前の epic だけ |
| `retry`・`giveUp` | ジョブ（`{ "type": "job", "epic", "id": <ジョブの ULID> }`） | 人が見たときの試行の番号（ジョブの `attempts`。試行の前に人に渡したジョブ（直しの上限を超えた直し）は `0`） | 空（`payloads/retry.schema.json`・`payloads/giveUp.schema.json`） |
| `addRepository` | リポジトリ（封筒の `repo`） | — | `platform`（`apple`。`payloads/addRepository.schema.json`）。同時に回す epic の上限は、最初の版では 1 に決めているので持たない |
| `configureRepository` | リポジトリ（封筒の `repo`。対象に加えた後） | — | `build`（`repo.json` の `build` と同じ形。`payloads/configureRepository.schema.json`）。送るたびに `build` をまるごと置き換える。`build` の中の知らない欄も含めて、知らない欄があれば読まない |
| `removeRepository`・`applyProtection` | リポジトリ | — | 設定 |
| `registerKey`・`revokeKey` | 公開鍵 | — | 公開鍵 |

リリースの操作（審査に出す・配信する など）の `kind` は、段階 5 で足す。

### 署名のしかた

- 方式は ECDSA P-256・SHA-256
- 署名する文字列は、封筒を RFC 8785（JSON Canonicalization Scheme）でそろえた UTF-8 のバイト列
- 署名は IEEE P1363 の形（r と s を 32 バイトずつつないだ 64 バイト）を base64url にしたもの（Android の Keystore が返す DER の形は、作る側で変換する）
- `keyId` は、公開鍵（SubjectPublicKeyInfo の DER）の SHA-256 を base64url にしたもの
- 人が読む中身は封筒の `payload` に入れ、署名で守る（`bodySha256` は、本文を封筒の外に書く目印の形のためのもので、状態リポジトリの意図では使わない）

人の意図は、状態リポジトリの `intents/<device>/<intent>.json` に `{"envelope": …, "sig": "…"}` をそのままファイルにして置く。人が読む本文は封筒の `payload` に入れるので、`bodySha256` を入れない（入っていれば受け付けない）。各リポジトリの目印として書く形（本文の後の `{"type":"intent",…}`）は、段階 1 で作った部品に残るが、使わない

### 確かめること

司令塔とワーカーは、人の意図を次の順に確かめ、1 つでも合わなければ指示として扱わない（理由を状態リポジトリに残し、クライアントに知らせる）。

1. 署名が、登録済みで取り消されていない鍵で正しい
2. 鍵に結びついたアカウントが、信用するアカウント（共同開発者を足すまでは 1 つ）。状態リポジトリは private で、書けるのは信用するアカウントだけ
3. 依頼の添付は、`attachments/` のファイルの大きさとハッシュが、封筒の `payload.attachments` と一致する
4. `target` と `targetVersion` が、今の状態と一致する（古い質問・古いゴール・承認の後に変わった PR への意図は受け付けない）
5. `nonce` がまだ使われていない（`consumed/` に記録が無い）
6. `issuedAt` が 7 日より古くない

#### 処理した記録（consumed）

```json
{ "v": 1, "kind": "approveMerge", "consumedAt": "…", "result": "rejected", "reason": "targetVersion が今の最終 PR の head と違う" }
```

- 司令塔は、確かめた意図ごとに、処理した後で `consumed/<keyId>/<nonce>.json` を版なしで作る。すでにあれば断られるので、同じ意図を 2 度記録しない。処理した記録の無い意図だけを `nonce` の順に処理し、処理はやり直しても結果が変わらない形にする（[flows.md](flows.md) の「司令塔の動き」）
- 置き場所（`intents/<device>/<nonce>.json`）と封筒の `keyId`・`nonce` が食い違う意図は、指示として扱わず、記録も作らない
- 記録するのは、署名を確かめられた意図だけにする（1〜3 が合ったもの）。署名の合わない意図の番号で記録を作ると、本物の意図を使えなくできてしまうため
- `result` は `accepted`（指示として扱った）か `rejected`（4・6 が合わなかった）。`reason` は `rejected` のときだけ書く

### 公開鍵の記録

`keys/<seq>.json` に、追記だけの記録の列として置く。`seq` は 1 からの連番。

```json
{
  "v": 1,
  "seq": 2,
  "action": "add",
  "keyId": "…",
  "publicKey": "<SubjectPublicKeyInfo の DER を base64url>",
  "account": "<GitHub のアカウント>",
  "label": "iPhone",
  "issuedAt": "2026-11-03T10:00:00Z",
  "previousSha256": "<seq 1 の記録のハッシュ>",
  "signedBy": "<登録済みの鍵の keyId>",
  "sig": "…"
}
```

- 署名は、`sig` を除いた記録を RFC 8785 でそろえた UTF-8 のバイト列に対して行う（封筒と同じ方式。知らない項目も署名に含める）
- `previousSha256` は、`sig` を含む前の記録全体をそろえたバイト列の SHA-256（16 進の小文字）
- `add` は `publicKey`・`account`・`label` を持ち、`revoke` は持たない。`keyId` は `publicKey` から求めた id と一致する
- 確かめるときは `seq` の順に読み、合わない記録（形の違い・連番の抜け・同じ `seq` の重なり・つながらない・署名した鍵が登録済みでない・登録済みの鍵の再登録・登録されていない鍵の取り消し・最後の鍵の取り消し・信用しないアカウント）があれば、その記録から後ろを使わず知らせる

- 最初の鍵（`seq` 1）は自分で署名する。司令塔とワーカーは、セットアップのときに最初の鍵の指紋を手で固定し、Keychain に置く
- 2 つ目からは、登録済みの鍵が署名する。`previousSha256` で前の記録とつなぎ、途中の書き換えや抜けを見つけられるようにする
- 取り消しは `action: "revoke"` の記録を足す
- 司令塔とワーカーは、確かめた一覧を Keychain に置き、状態リポジトリの記録は「新しい記録があるか」を見るためだけに使う
- 一覧は、前に確かめた記録の続きであるときだけ更新する。記録が前より短い・前に確かめた最後の記録が違う（取り消しの記録を消して鍵を戻すなど）ときは、一覧を変えずに知らせる。Keychain には、確かめた記録の数と、最後の記録のハッシュも置く

## 決めていないこと

- リリースの操作の `kind` と、App Store の素材の形（段階 5）
- クライアントでの `repo.json` の `build` の入れ方（今は非常口の `askhub configure-repository` だけ。[operations.md](operations.md) の「ビルドの設定の入れ方」）
