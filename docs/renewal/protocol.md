# プロトコル

クライアント・司令塔・ワーカー・GitHub Actions がやり取りする形を決める。
この文書は形の案で、実装では JSON Schema と、入力と出力のテスト用の例を正本にする（Swift と、後から作る Kotlin の両方のテストで同じ例を読む）。

## 置き場所の全体

| 置き場所 | 置くもの | 読むもの |
| --- | --- | --- |
| 状態リポジトリ（private。1 つ） | 機械の状態（対象のリポジトリの設定・epic・ゴール・質問の状態・ジョブ・試行・Mac の印・端末の宛先・公開鍵の記録・公開のスレッドに置かない人の意図） | クライアント・司令塔・ワーカー |
| 各リポジトリの Discussion | 依頼の要約、質問、回答・説明・おまかせ（人の意図）、説明、ゴールの写し | 人・クライアント・司令塔 |
| 各リポジトリの PR | 子 PR、最終 PR、判断のカードの写し、最終 PR への指示・カードへの答え・マージの承認（人の意図） | 人・クライアント・司令塔・ワーカー |

人が GitHub の画面で読めるものは各リポジトリに残し、機械が判断に使う正本は状態リポジトリに置く。両方にあるもの（質問・ゴール・判断のカード）は、状態リポジトリが正本で、各リポジトリのものは人が読むための写しとする。

## 状態リポジトリ

置き場所は `shilokuma-inc/askhub-state`（private）。

### ファイルの置き方

書き手ごとにファイルを分け、1 つのファイルの書き手は 1 つにする。

```
version.json                                       形の版（書き手: 人が作るときだけ）
repos/<owner>/<repo>/repo.json                     対象のリポジトリの設定（司令塔）
repos/<owner>/<repo>/epics/<epic>/epic.json        epic の状態（司令塔）
repos/<owner>/<repo>/epics/<epic>/questions.json   質問と、その状態（司令塔）
repos/<owner>/<repo>/epics/<epic>/goal.json        ゴール（司令塔）
repos/<owner>/<repo>/epics/<epic>/decisions.json   人が決めていない判断（司令塔）
repos/<owner>/<repo>/epics/<epic>/jobs/<job>.json  ジョブ（司令塔）
repos/<owner>/<repo>/epics/<epic>/attempts/<job>/<n>.json  試行（実行した Mac のワーカー）
macs/<mac>.json                                    Mac の生きている印（その Mac のワーカー・司令塔）
devices/<device>.json                              通知の宛先（その端末のクライアント）
keys/<seq>.json                                    公開鍵の追記の記録（クライアント。署名つき）
intents/<device>/<intent>.json                     公開のスレッドに置かない人の意図（クライアント。署名つき）
consumed/<device>/<intent>                         処理した人の意図の記録（司令塔）
```

- `<epic>`・`<job>`・`<intent>` は ULID（時刻の順に並ぶ一意な id）
- `<mac>` は Mac ごとに決める短い名前、`<device>` は端末の公開鍵の id（下の「署名」）
- リポジトリ単位の作業でない人の意図（対象に加える・保護の設定・Mac の設定など）は、`repos/` の外の `intents/` に置く
- 終わった epic（マージ済み・やめたもの）は、マージかやめてから 30 日後に `archive/` に移し、まとめて畳む

### 共通の決まり

- どのファイルも、先頭に `"v"`（そのファイルの形の版）を持つ。知らない版のファイルは読まずに知らせる
- 時刻は UTC の ISO 8601 で、秒まで（`2026-11-03T10:00:00Z`）。小数の秒と時差の表記は使わない
- パスに使う値（リポジトリの owner/name・ULID・鍵の id）は、読むときに形を確かめる。`..` や `/` を含む値で、ほかのファイルを指せないようにする（形は `protocol/schemas/common.schema.json`）
- 書き込みは Contents API で、読んだときの版（sha）を付けて行う。409（版が合わない）が返ったら読み直してやり直す
- 読み取りは `git fetch` か、ETag つきの要求で行う
- 空の一覧や 404 を理由に、ファイルを作り直さない（GitHub の障害で一覧が空で返ることがある）

### repo.json（対象のリポジトリ）

```json
{
  "v": 1,
  "repo": "shilokuma-inc/prime-pick-ios",
  "platform": "apple",
  "allowedMacs": ["*"],
  "maxConcurrentEpics": 1,
  "appKit": { "ref": "<共通リポジトリのコミット>" },
  "protection": { "appliedAt": null },
  "addedAt": "2026-11-03T10:00:00Z"
}
```

- `allowedMacs` は、実装を回してよい Mac の名前の一覧。`"*"` はすべての Mac

### epic.json

```json
{
  "v": 1,
  "id": "01JC…",
  "repo": "shilokuma-inc/prime-pick-ios",
  "title": "ランキングの表示を変える",
  "discussion": 512,
  "stage": "asking",
  "mac": null,
  "branch": null,
  "finalPullRequest": null,
  "goalVersion": null,
  "createdAt": "…",
  "updatedAt": "…"
}
```

`stage` の値と移り変わり:

| stage | 意味 | 次 |
| --- | --- | --- |
| `drafting` | 依頼を受け、質問を作っている | `asking` |
| `asking` | 人の回答を待っている（説明待ち・ロックを含む） | `checking` |
| `checking` | 着手前の確認をしている | `asking`（追加の質問）・`awaitingStart` |
| `awaitingStart` | ゴールの確認と開始を待っている | `running`・`checking`（ゴールの修正） |
| `running` | 実装している | `finalizing` |
| `finalizing` | 最終 PR の前の検証と、最終 PR の対処をしている | `reviewing`・`merged` |
| `reviewing` | 人が決めていない判断の確認とマージを待っている | `finalizing`（直してほしい）・`merged` |
| `merged` | マージされた | — |
| `abandoned` | やめた | — |

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
      "dependsOn": [],
      "state": "open",
      "comment": 1234567,
      "answer": null
    }
  ]
}
```

- `state` は `locked`（依存先の回答待ち）・`revising`（依存先が決まり、見直し中）・`open`（回答を待つ）・`clarifying`（説明を作成中）・`answered`・`delegated`（おまかせ）
- `version` は質問を書き直すたびに上げる。回答の人の意図は、回答した質問の `version` を持つ。古い版への回答は受け付けず、知らせる
- `comment` は、Discussion の質問のコメントの id（人が読むための写し）

### goal.json

```json
{
  "v": 1,
  "version": 2,
  "summary": "…",
  "decided": [ { "question": "q1", "text": "日ごとに入れ替える" } ],
  "delegated": [ { "question": "q3", "text": "推奨の…にした" } ],
  "outOfScope": [ "…" ],
  "doneWhen": [ "…" ],
  "tasks": [
    { "id": "t1", "title": "…", "dependsOn": [], "humanTask": false, "state": "pending" }
  ],
  "humanTasks": [
    { "id": "h1", "title": "App Store Connect で課金のアイテムを作る", "why": "…", "steps": ["…"], "links": ["…"], "handover": "none", "state": "pending" }
  ]
}
```

- ゴールを直すたびに `version` を上げる。「開始」の人の意図は、確かめたゴールの `version` を持つ
- タスクの `state` は `pending`・`locked`（人がする作業の待ち）・`running`・`done`

### decisions.json（人が決めていない判断）

```json
{
  "v": 1,
  "items": [
    {
      "id": "d1",
      "source": "provisional",
      "visible": true,
      "what": "見出しの文言を短くした",
      "why": "ゴールの t2（iPhone の幅に収める）",
      "alternatives": ["2 行にする"],
      "screenshots": { "before": "<添付の参照>", "after": "<添付の参照>" },
      "answer": null
    }
  ]
}
```

- `source` は `delegated`（おまかせ）か `provisional`（ループの仮決め）
- `visible` は、ユーザーから見える挙動・仕様・見た目に関わるか。決めるのは、読むだけのレビュー役の Claude と、決まった信号（View・文言・アセット・Info.plist・entitlements の差分、スクショの差）
- `answer` は人の意図（OK・別案・直してほしい）への参照

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
  "createdAt": "…",
  "updatedAt": "…"
}
```

- `kind` の最初の一覧: `makeQuestions`・`explain`・`reviseQuestion`・`checkReadiness`・`reviseGoal`・`prepareWorkspace`・`implementTask`・`fixTask`・`integrateDevelop`・`verifyBeforeFinal`・`openFinalPullRequest`・`fixFinalPullRequest`・`rerunChecks`・`classifyDecisions`・`captureScreenshots`・`mergeFinalPullRequest`・`cleanUp`・`notify`
- `state` は `queued`・`assigned`・`running`・`succeeded`・`failed`・`waitingHuman`・`paused`・`canceled`
- ジョブのファイルは司令塔だけが書く。ワーカーは、自分の試行のファイルに「始めた」を書くことで、ジョブを引き受けたことを示す。司令塔は試行を読んでジョブの `state` を更新する

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
- `failure` は `{ "class": "…", "message": "…", "logExcerpt": "…" }`。ログの抜粋は、トークンらしい文字列を伏せてから書く
- 失敗の区分（`class`）: `runnerUnavailable`・`flaky`・`buildFailed`・`testFailed`・`reviewRequired`・`conflict`・`usageLimit`・`authExpired`・`githubOutage`・`macOffline`・`timeout`・`unexpected`（扱いは [architecture.md](architecture.md) の表）
- `heartbeatAt` は、長い試行の途中で一定の間隔で書く。古いまま止まった試行は、司令塔が `macOffline` か `timeout` として扱う

### macs/<mac>.json（Mac の生きている印）

```json
{
  "v": 1,
  "mac": "macbook-a",
  "kind": "resident",
  "roles": ["worker"],
  "seenAt": "…",
  "versions": { "worker": "1.0.0", "claude": "2.1.316", "xcode": "27.1" },
  "diskFreeGB": 120,
  "load": 3.2,
  "capacity": { "claude": 2, "build": 1 },
  "selfCheck": { "keychain": "ok", "githubToken": "ok", "claudeToken": "ok", "tokenExpiresAt": "…" }
}
```

- `kind` は `alwaysOn`・`resident`・`manual`
- 変化があったときと、一定の間隔（10 分程度）でだけ書く

### devices/<device>.json（通知の宛先）

```json
{ "v": 1, "device": "<鍵の id>", "platform": "ios", "apnsToken": "…", "updatedAt": "…" }
```

## 各リポジトリに書く目印

HTML のコメントの形で、本文の末尾に置く。1 つのコメントに 1 つだけ。書式は 1 つにそろえる。

```
<!-- askhub v1 {"type":"…", …} -->
```

- `type` は、機械が書くもの（`question`・`explanation`・`goal`・`decisions`・`status`・`finalPullRequest` など）と、人の意図（`intent`）
- 人の意図の目印だけを、指示として扱う（下の「署名」）。機械の目印は、表示と照らし合わせのために使う
- 引用の中の目印は読まない（目印は、コメントの本文の最後の行でなければならない）

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
| `answer` | 質問 | 質問の `version` | `mode`（`answer`・`clarify`・`delegate`）、`choice`、`note` |
| `startEpic` | epic | ゴールの `version` | `mac` |
| `reviseGoal` | epic | ゴールの `version` | 指示の本文 |
| `decision` | 判断のカード | 最終 PR の head のコミット | `answer`（`ok`・`alternative`・`fix`）、本文 |
| `approveMerge` | 最終 PR | 最終 PR の head のコミット | — |
| `instructFinal` | 最終 PR | 最終 PR の head のコミット | 指示の本文 |
| `humanTaskDone` | 人がする作業 | ゴールの `version` | 渡すものの参照 |
| `handover` | epic | — | 移す先の Mac |
| `retry`・`giveUp` | ジョブ | 試行の番号 | — |
| `addRepository`・`removeRepository`・`applyProtection` | リポジトリ | — | 設定 |
| `registerKey`・`revokeKey` | 公開鍵 | — | 公開鍵 |

リリースの操作（審査に出す・配信する など）の `kind` は、段階 5 で足す。

### 署名のしかた

- 方式は ECDSA P-256・SHA-256
- 署名する文字列は、封筒を RFC 8785（JSON Canonicalization Scheme）でそろえた UTF-8 のバイト列
- 署名は IEEE P1363 の形（r と s を 32 バイトずつつないだ 64 バイト）を base64url にしたもの（Android の Keystore が返す DER の形は、作る側で変換する）
- `keyId` は、公開鍵（SubjectPublicKeyInfo の DER）の SHA-256 を base64url にしたもの
- 人が読む本文は封筒の外に書き、そのハッシュを `bodySha256` に入れる

各リポジトリに書くときは、人が読む本文の後に目印として置く。

```
回答: 日ごと
夜間はもっと長くてもよい。

<!-- askhub v1 {"type":"intent","envelope":{…},"sig":"…"} -->
```

状態リポジトリの `intents/` に置くときは、`{"envelope": …, "sig": "…"}` をそのままファイルにする。

### 確かめること

司令塔とワーカーは、人の意図を次の順に確かめ、1 つでも合わなければ指示として扱わない（理由を状態リポジトリに残し、クライアントに知らせる）。

1. 署名が、登録済みで取り消されていない鍵で正しい
2. 書き手の GitHub のアカウントが、鍵に結びついたアカウントと同じ（共同開発者を足すまでは、1 つのアカウントだけ）
3. `bodySha256` が、目印の前の本文と一致する
4. `target` と `targetVersion` が、今の状態と一致する（古い質問・古いゴール・承認の後に変わった PR への意図は受け付けない）
5. `nonce` がまだ使われていない（`consumed/` に記録が無い）
6. `issuedAt` が 7 日より古くない

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
  "previousSha256": "<seq 1 の記録のハッシュ>",
  "signedBy": "<登録済みの鍵の keyId>",
  "sig": "…"
}
```

- 最初の鍵（`seq` 1）は自分で署名する。司令塔とワーカーは、セットアップのときに最初の鍵の指紋を手で固定し、Keychain に置く
- 2 つ目からは、登録済みの鍵が署名する。`previousSha256` で前の記録とつなぎ、途中の書き換えや抜けを見つけられるようにする
- 取り消しは `action: "revoke"` の記録を足す
- 司令塔とワーカーは、確かめた一覧を Keychain に置き、状態リポジトリの記録は「新しい記録があるか」を見るためだけに使う

## 決めていないこと

- リリースの操作の `kind` と、App Store の素材の形（段階 5）
