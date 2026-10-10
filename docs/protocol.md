# AskHub プロトコル

AskHub アプリ・オーケストレーター・ループ（Claude）が、GitHub 上で「人間の判断が必要なもの」を
やり取りするための取り決め。決定の経緯は [Discussion #1](https://github.com/shilokuma-inc/ask-hub-apple/discussions/1) を参照。

このドキュメントで実装済みの仕様を変更するときは、`AskHubKit` の対応する実装も合わせて更新すること。
ラベルは `AskHubLabel`、質問の目印は `QuestionMarker`、回答の形式は `Answer`、
信用する author と回答済みの判定は `TrustedAuthors`、仮決め一覧の行の読み取りは `DecisionLogItem` が実装している。
「要対応」に出す未回答の質問と「任意判断」「実機確認」に出す Issue の取得は `InboxFetcher`（GitHub からの取得は `GitHubInboxSource`）が実装している。

## 登場するもの

| 名前 | 役割 |
| --- | --- |
| アプリ | iOS / macOS の受信箱。質問の一覧・回答・依頼・最終 PR のマージを行う。GitHub だけを見る |
| オーケストレーター | Mac に常駐する CLI（`askhub-orchestrator`）。ラベルと回答を検知してループを起動・再開する |
| ループ（Claude） | 実装を進め、人間の判断が必要な点を質問として GitHub に書き込む |
| 信用する author | 質問・回答・依頼を出してよい GitHub アカウント |

## ラベル

すべてのリポジトリで同じ名前を使う。`AskHubKit` の `AskHubLabel` と一致させる。

| ラベル | 付ける対象 | 意味 | 付ける側 | 外す側 |
| --- | --- | --- | --- | --- |
| `needs-answer` | Discussion / PR / Issue | 未回答の質問がある | 質問を出した側（Claude / ループ） | オーケストレーター（すべて回答済みになったとき） |
| `ready-for-loop` | Discussion | 回答が確定し、ループを始めてよい | オーケストレーター（質問がすべて回答されたとき）／アプリ（最後の未回答の質問を「投稿したら、回答を確定してループを始める」で、回し方を「オーケストレーターで始める」にして投稿したとき） | オーケストレーター（ループを起動したとき）／手で回すループ（始めるとき） |
| `manual-loop` | Discussion | この Discussion のループは手で回す。オーケストレーターは `ready-for-loop` を付けず、起動もしない（信用する author の Discussion に付いたときだけ効く） | アプリ（最後の未回答の質問を「投稿したら、回答を確定してループを始める」で、回し方を「手動で回す」にして投稿したとき。`ready-for-loop` は付けない）／人間（GitHub で手で付けてもよい） | — （epic が終われば Discussion ごと閉じる） |
| `decision-log` | Issue | epic ごとの仮決め一覧（判断ログ） | ループ | — （最終 PR がマージされたら、オーケストレーターが Issue を閉じる。下記「仮決め一覧」） |
| `needs-verify` | Issue | 実機・実データでの確認が必要 | ループ | — （人間が確認して閉じる。アプリの実機確認の詳細画面からも閉じられる） |
| `idea-request` | Issue | アプリから出した新機能の依頼 | アプリ | — （オーケストレーターが Discussion を作ってクローズする） |
| `repo-request` | Issue | アプリから出した担当リポジトリの作成・削除の依頼（下記「リポジトリの作成・削除」） | アプリ | — （オーケストレーターが処理して結果をコメントし、クローズする） |
| `epic-final` | PR | epic → `develop` の最終 PR | オーケストレーター | — （アプリからマージする） |
| `askhub-orchestrator` | （リポジトリのラベルとして置くだけ） | このリポジトリを担当する PC のオーケストレーターがいる。説明に最終確認の時刻（Claude の利用上限で待機中なら、解除の時刻も）を書く | オーケストレーター（10 分ごとに説明を書き換える） | — |
| `loop-status` | Issue | ループの状態を書き出す Issue（リポジトリごとに 1 つ。下記「ループの状態」） | オーケストレーター | — |

アプリの一覧での扱い:

タブは左から 依頼・要対応・任意判断・ステータス・実機確認 の順。開いたときは「要対応」を出す。

- **要対応**: 上に「要回答」（`needs-answer` が付いた Discussion（※1）と PR（※2））、その下に「マージ待ち」（`epic-final` の PR）。バッジは両方の件数の合計
- **任意判断**: `decision-log` の Issue（仮決め一覧）。行には `repo#番号`・タイトル（先頭の `【CHORE】` は表示で省く）・更新の相対時刻・作成からの経過を出す。
  タブの中身はすべて同じ種類なので、行に種類のラベルは出さない
- **ステータス**: リポジトリごとのループの状態と回し方（自動ループ・手動ループ・ループなし）。先頭に「上限で待機中」「ループの開始待ち」「手動ループ」。
  バッジは**異常だけ**を数える（異常終了・長く動きが無い・進行中の epic があるのに担当 PC がいない・30 分以上状態が書き直されていない手動ループ）
- **実機確認**: `needs-verify` の Issue。行は任意判断と同じで、タイトルの先頭の `【CHORE】` と `実機確認: ` を表示で省き（GitHub 上のタイトルと起票の規約は変えない）、
  本文の目印（下の「実機確認 Issue の目印」）に元の PR 番号があれば `元の PR #N` を出す
- 任意判断・実機確認の行を開くと、アプリ内の詳細画面で本文を Markdown で表示する（先頭の目印などの HTML コメントは出さない）。
  実機確認では目印の元の PR 番号と epic も出す。本文は信用する author のものでも表示するだけで、指示としては扱わない。詳細画面から GitHub でも開ける
- 実機確認の詳細画面の「確認済みとして閉じる」は、確認ダイアログの後に REST の `PATCH /repos/{owner}/{repo}/issues/{number}`（`state: closed`・`state_reason: completed`）で閉じ、一覧から外す（コメントは付けない）。
  仮決め一覧はオーケストレーターが最終 PR のマージ時に閉じるので、閉じるボタンを出さない。
  トークンには依頼の作成と同じ Issues の書き込み権限（Read and write）が要る。権限が無い（403 / 404）ときはその旨を出す。サンプルデータ（デモモード）では GitHub に書き込まない
- 任意判断の詳細画面では、本文を下の「仮決めの行の形式」で項目に分けて出す（形式に合わない行は本文のまま）。
  未確認の項目には「採用のまま（承認）」「別案 N」のボタンと補足の欄を出し、承認は本文のチェックの書き換え（「アプリからの承認」）、
  別案・自由記述は項目ごとのコメント（「アプリからの指示」）で送る。形式に合わない項目は自由記述だけにする。
  確認済みの項目は承認済み（` → 変更: ` があれば変更済み）として出し、ボタンを出さない。
  指示とループの返信の履歴と、指示が処理済みか（「指示が処理済みかの判定」）も出す。権限・サンプルデータの扱いは実機確認の「確認済みとして閉じる」と同じ
- ステータスの行は `loop-status` の Issue から読む（下の「ループの状態」）
- **上限で待機中**（ステータスの先頭）: `askhub-orchestrator` の説明に解除の時刻があるリポジトリ。再開の時刻を出す
- **ループの開始待ち**（ステータスの先頭。上限で待機中の下）: `ready-for-loop` の Discussion。`askhub-orchestrator` の時刻が 30 分より古い・無いリポジトリは「担当 PC なし」。担当 PC が上限で待機中なら「上限で待機中（〇時に再開）」

対象はアプリの設定（「取得する organization」）に並べた organization 全体で、ラベルで検索する（リポジトリの列挙は設定しない）。
既定は `shilokuma-inc` だけ。検索は `org:a org:b` と並べて 1 回で行い、`organization.repositories` を読む取得（ループ・上限で待機中・依頼先）は organization ごとに順に行う。

## ループの状態

アプリは Mac の中を見られないので、オーケストレーターが担当リポジトリごとにループの状態を Issue に書き出し、アプリはそれを読む
（[Discussion #197](https://github.com/shilokuma-inc/ask-hub-apple/discussions/197) の Q1・Q2）。形式は `AskHubKit` の `LoopStatusReport` が実装している。

- Issue はリポジトリごとに 1 つ。ラベル `loop-status`、タイトル `【AskHub】ループの状態`
- 本文の**先頭**に機械が読める目印を置き、続けて人が読める表を置く。アプリが読むのは目印だけ
- **信用する author が作った Issue だけを読む**（public リポジトリでは誰でも同じラベルの Issue を作れる）
- public リポジトリでは誰でも読めるので、epic 名・Discussion の番号・件数・時刻だけを書く。**ローカルパス・ログの中身・PC 名・トークンは書かない**

```html
<!-- ask-hub:loop-status {"checkedAt":"2026-10-06T00:10:00Z","discussion":197,"epic":"epic/loop-status","lastActivityAt":"2026-10-06T00:07:00Z","progress":{"completed":5,"deferred":1,"total":12},"state":"running","writer":"orchestrator"} -->
```

目印の中身は JSON（キーの順は問わない。知らないキーは無視する）。時刻は秒までの ISO 8601（UTC）。
文字列の中の `>` は `\u003e` にエスケープし、目印の終わり（`-->`）と取り違えないようにする。

| キー | 必須 | 内容 |
| --- | --- | --- |
| `state` | 必須 | 状態の分類（下表） |
| `checkedAt` | 必須 | 書き手が最後に確かめた時刻。状態が変わらなくても 10 分ごとに書き直す |
| `writer` | 任意 | 書き手。`orchestrator`（オーケストレーター）か `manual`（手で回しているループ）。キーが無ければ `orchestrator` として読む（`writer` を足す前の目印との互換）。オーケストレーターも明示して書く |
| `epic` | 任意 | 統合ブランチ（例: `epic/loop-status`） |
| `discussion` | 任意 | ゴール元の Discussion の番号 |
| `progress` | 任意 | goal のチェックボックスの数。`completed`（`[x]`。保留で閉じたものを含む）と `total`、任意で `deferred`（`completed` のうち保留で閉じたもの。`[x]` かつ `※保留` を含む行） |
| `lastActivityAt` | 任意 | ループが最後に動いた時刻 |
| `usageLimitedUntil` | 任意 | Claude の利用上限の解除の時刻（`usage-limited` のとき） |
| `runner` | 任意 | 手動ループを回している人の login（`writer` が `manual` のとき）。オーケストレーターは書かない |
| `waitingPullRequests` | 任意 | 手動ループで回答を待っている PR の番号。これらの `needs-answer` がすべて外れ、ループが止まっていれば、アプリが担当者に再開を促す |

| `state` | 表の表記 | 意味 |
| --- | --- | --- |
| `running` | 実行中 | ループが動いている |
| `waiting-for-answer` | 回答待ち | 回答待ちのタスクだけが残っている（PR の ask が未回答） |
| `usage-limited` | 上限で待機中 | Claude の利用上限で待機している |
| `waiting-to-start` | 開始待ち | epic のタスクが残ったままループが止まっている（再開待ち・手で止めた）、または `ready-for-loop` の Discussion があるがまだ起動していない |
| `gave-up` | 異常終了（再開を諦めた） | 異常終了し、自動の再開を諦めた |
| `completed` | 完了（最終 PR のマージ待ち） | 全タスクが終わり、最終 PR のマージを待っている |
| `no-loop` | ループなし | ループが無い |

- 複数に当てはまるときは、上限で待機中 → 実行中 → 異常終了 → epic の進み具合（開始待ち・回答待ち・完了）→ `ready-for-loop` の開始待ち → ループなし の順に優先する（`OrchestratorKit` の `LoopStatusSummary`）。
  完了した epic の最終 PR がマージされるまでは、次の Discussion に `ready-for-loop` が付いていても「完了」を出す
- `epic`・`discussion`・`progress`・`lastActivityAt` は、制御用 worktree が準備を終えた `epic/` のブランチにあるときだけ書く。
  epic が無く `ready-for-loop` を待っているときは、`discussion` にその Discussion の番号を書く
- `progress.deferred` は `completed` の内訳で、`completed` の意味は変えない（古いアプリは `deferred` を無視して今と同じ表示になる）。
  古いオーケストレーターは書かないので、アプリは `deferred` が無ければ保留を区別しない表示にする。新しいオーケストレーターは 0 件でも書く
- アプリが知らない `state` は「不明」として扱う（新しいオーケストレーターが分類を足しても読めなくならないように）
- アプリが知らない `writer` も「不明」として扱う
- 「担当 PC なし」は書き出さない。`checkedAt` が 30 分より古いとき、アプリがそう判断する（`askhub-orchestrator` の印と同じ）
- オーケストレーターは、`checkedAt` 以外が変わったときに本文を書き換え、変わらなければ 10 分ごとに `checkedAt` だけを書き直す
- 手動ループ（`manual-loop` の Discussion）は、担当者の Claude が `scripts/askhub-manual.sh status` で `writer` を `manual`・`runner` を担当者にして、
  状態・epic・進捗・回答待ちの PR を書き、10 分ごとに `checkedAt` を書き直す。
  信用する author の open な `manual-loop` の Discussion があるあいだ、オーケストレーターは書き手が `manual` の状態を（`checkedAt` が古くなっても）上書きしない。
  古くなったことはアプリが知らせる。Discussion が閉じた後、`checkedAt` が 30 分を過ぎていれば、オーケストレーターが書き直す

アプリの読み方（`LoopStatusFetcher`。GitHub からの取得は `GitHubLoopStatusSource`）:

- `organization.repositories` の GraphQL で、リポジトリごとに担当の印（`askhub-orchestrator` の説明）と open な `loop-status` の Issue を一緒に読む（Search API は使わない）。
  リポジトリも Issue もページングを最後まで追う
- 信用する author が作り、目印を読める Issue のうち、最も新しく更新されたものを使う
- 行にするのは、担当の印か信用する author の状態用の Issue があるリポジトリ（Q4: 担当 PC のいるリポジトリをすべて出す）。
  担当の印も `checkedAt` も 30 分より古ければ「担当 PC なし」、担当 PC はいるが状態用の Issue が無ければ「状態なし」とする
- `loop-status` の Issue は「任意判断」「実機確認」などの一覧には出さない（一覧はラベルで検索しており、`loop-status` を含めない）
- 担当から外したリポジトリの状態用の Issue は、オーケストレーターが閉じる（ステータスタブに「担当 PC なし」の行を残さない）

## 質問の目印

質問のコメント本文の**先頭**に、次の HTML コメントを置く。GitHub 上では表示されない。

```html
<!-- ask-hub:question id="<リポジトリ内で一意な文字列>" options="選択肢1|選択肢2|選択肢3" -->
```

| 属性 | 必須 | 内容 |
| --- | --- | --- |
| `id` | 必須 | リポジトリ内で一意な文字列。例: Discussion なら `d12-q1`、PR なら `pr34-1` |
| `options` | 任意 | 選択肢を `\|` で区切って並べる。省略した場合は自由記述のみの質問になる |

- 属性値はダブルクォートで囲む。属性の順序は問わない
- エスケープの規則は無い。`id` と選択肢には `"`・改行・`-->` を含めず、選択肢には `|` を含めない（前後の空白は取り除かれる）
- 目印の無いコメントは質問として扱わない
- **信用する author 以外が書いた目印は無視する**（public リポジトリでは誰でもコメントできるため）
- 1 つのコメントに置く質問は 1 つだけ

例:

```markdown
<!-- ask-hub:question id="d12-q3" options="24時間|1時間|送信1回分" -->
### Q3. レート制限の単位
送信の上限をどの単位で数えますか？
```

## 質問の場所

| 種類 | 場所 | 回答の書き方 |
| --- | --- | --- |
| ※1 Discussion の質問 | Discussion に、質問 1 つにつき 1 コメントで投稿する | そのコメントへの返信（スレッド） |
| ※2 PR の ask | PR のレビューコメント（`ask-badge` 付き） | そのコメントへの返信（`in_reply_to`） |

質問を出したら、その Discussion / PR に `needs-answer` を付ける。

`needs-answer` は Discussion #1 の決定どおり Issue にも付けられるが、MVP では Issue 上の質問の書き方を定義しない。
アプリの「要対応」の「要回答」に出すのは Discussion（※1）と PR（※2）だけで、`needs-answer` の付いた Issue は一覧に出さない。

## 回答済みの判定

質問コメントへの返信のうち、**信用する author のものが 1 件以上あれば回答済み**とする。
信用する author 以外の返信は回答として扱わない。

## 回答の形式

アプリが投稿する返信の本文は次の形式にする。

```text
回答: <選んだ選択肢>
<任意の自由記述>
```

- 1 行目は `回答: ` に続けて、`options` のいずれか 1 つをそのまま書く
- 2 行目以降は任意の自由記述（補足・条件など）
- `options` の無い質問は、自由記述だけを書く（`回答: ` の行は付けない）

例:

```text
回答: 1時間
夜間はもっと長くてもよい。
```

## ゴール元の Discussion の目印

オーケストレーターは、最終 PR（`epic-final`）の本文の先頭に、epic のゴール元の Discussion を書く。

```
ゴール元: Discussion #12
<!-- ask-hub:discussion 12 -->
```

- 番号は、起動スクリプト（askhub-start-loop）が制御用 worktree に残す `.claude/askhub-bootstrap.local.txt` から読む。
  手動ループの epic では、`scripts/askhub-manual.sh final` が最終 PR を作るときに付ける
- 最終 PR が `develop` にマージされると、ワークフロー（`.github/workflows/close-goal-discussion.yml`）がこの目印を読み、
  Discussion に PR へのリンクをコメントしてから解決済みで閉じる

## 実機確認 Issue の目印

ループは、実機確認 Issue（`needs-verify`）の本文の**先頭**に目印を置く。
アプリはこの目印を読んで、元の PR 番号と統合ブランチを取り出す（`AskHubKit` の `VerifyMarker`）。

```html
<!-- ask-hub:verify {"epic":"epic/xxx","pullRequest":123} -->
```

| キー | 必須 | 内容 |
| --- | --- | --- |
| `pullRequest` | 任意 | 実機確認のきっかけになった PR の番号 |
| `epic` | 任意 | 統合ブランチ（例: `epic/verify-tab-ui`）。元の PR が無い場合も書いてよい |

- キーの順は問わない。知らないキーは無視する
- 文字列の中の `>` は `\u003e` にエスケープし、目印の終わり（`-->`）と取り違えないようにする
- 目印が無い既存の Issue では、元の PR 番号と epic は取り出さない（自由文からの推測は行わない）
- アプリは「任意判断」「実機確認」の Issue の検索で本文と作成日も読み（検索の回数は変えない）、`needs-verify` の Issue の本文からだけ目印を読む（`InboxIssue.verifyMarker`）
- **信用する author が作った Issue の目印だけを読む**（public リポジトリでは誰でも同じ Issue を作れる）

## 仮決め一覧

ループは、ask にしない判断（仮決め）を epic ごとの Issue（`decision-log`、タイトル `【CHORE】<epic ブランチ> の仮決め一覧`）に 1 行ずつ書く。
人間はチェックで承認し、変えたいものはコメントで指示する（`#<PR番号> は別案 1 で` など）。仮決めはマージを止めない。

| 時期 | 人間の返答の扱い |
| --- | --- |
| ループが動いている間 | ループが周回の最初に読み、別案の指示は修正タスクにする |
| ループが止まってから最終 PR をマージするまで | オーケストレーターが未処理の指示を見つけてループを再開する（epic のタスクがすべて完了していても再開する）。ループの開始を確かめ、再び完了したら、最終 PR の本文を書き直す |
| 最終 PR のマージ時 | オーケストレーターが Issue を閉じる。チェックの無い仮決めは、既定値のまま確定したと列挙してから閉じる |
| マージ後 | 扱わない（ループも epic も終わっている）。変えたいものは Issue か AskHub の依頼から出す |

- ループと人間は同じアカウントでコメントするため、ループの返信の先頭には `<!-- ask-hub:decision-reply -->` を置く。
  オーケストレーターは、最後のこの目印より後にある信用する author のコメントを「未処理の指示」とみなす
- ループは信用する author のコメントすべてに目印付きで返信する（指示でないコメントにも）。返信しないと、ループが止まった後に同じ epic を再開しうる。
  同じコメントで再開するのは 1 回だけ（ループの開始を確かめられなかったときは、上限まで再開し直す）
- オーケストレーターの閉じるときのコメントの先頭には `<!-- ask-hub:decision-close -->` を置く
- 最終 PR をマージせずに閉じたときは、仮決め一覧を開いたままにする（人間が判断する）

### 仮決めの行の形式

ループは本文の冒頭の説明の後に、仮決めを 1 行ずつ次の形式で書く。

```text
- [ ] #<PR番号> <判断の対象> → 採用: <値>（別案: <案1> / <案2>）
```

アプリはこの形式の行を項目として読み、チェックの有無・PR 番号・判断の対象・採用・別案を取り出す。

- チェックは `- [ ]`（未確認）と `- [x]`（`- [X]` も可。確認済み）。行頭の空白は無視する
- 判断の対象は `#<PR番号> ` の後から最初の ` → 採用: ` まで。採用は、その後から末尾の `（別案: …）` の前まで
- 別案は末尾の `（別案: …）` の中を ` / ` で区切ったもの。`（別案: …）` が無い行は別案 0 件として読む。空の別案がある行（`（別案: 赤 / ）` など）は形式に合わない行として扱う
- ループが指示を受けて行の末尾に ` → 変更: <内容>` を追記した行（`- [x] #319 … → 採用: …（別案: …） → 変更: 別案 1（…）`）は、
  最後の ` → 変更: ` から後を変更の内容として読み、採用・別案はその前の部分から読む
- `#<PR番号> ` で始まらない・` → 採用: ` が無いなど形式に合わない行のうち、チェックで始まるものは「形式に合わない項目」として本文のまま出す。
  チェックで始まらない行（冒頭の説明など）は項目にしない
- 読み取りは表示のためだけに使う。本文を書き換えるときは、読み取った値から行を組み立て直さない（下記）

### アプリからの承認（本文のチェック）

承認は今の取り決めどおり**本文のチェック**で表す。アプリは承認でコメントを投稿しない。

1. 書き換えの直前に、REST の `GET /repos/{owner}/{repo}/issues/{number}` で本文を読み直す
2. 画面に表示したときの行と、チェックの後ろの文字列が**全文一致する未確認の行**を探す（行頭の空白・行末の空白は比べない）。
   同じ文字列の行が複数あれば最初の 1 行にする
3. 見つかった行の `- [ ]` だけを `- [x]` に変え、ほかの行・改行コード・行の残りはそのまま残して `PATCH /repos/{owner}/{repo}/issues/{number}`（`body`）で書き戻す
4. 同じ文字列の行がすでに確認済みなら、書き換えずに承認済みとして扱う。どちらも見つからない（ループが書き換えた・消えた）ときは書き換えず、
   本文を読み直して表示し直すよう促す

- ループ・オーケストレーターは承認の書き換えを再開のきっかけにしない（今の取り決めどおり）。
  ループは playbook の B-0 で本文の編集者を確かめてからチェックを承認として扱うので、アプリはトークンの持ち主として書き換える
- GitHub には条件付きの書き込みが無いため、読み直しから書き戻しまでの間にループが本文を書き換えると、その変更を上書きしうる（ごく短い間なので受け入れる）

### アプリからの指示（項目ごとのコメント）

別案・自由記述の指示は、**項目ごとに 1 件のコメント**として選んだ時点で投稿する（`POST /repos/{owner}/{repo}/issues/{number}/comments`）。
まとめて送る下書きは作らない。ループは今の playbook の B-0 のまま、信用する author のコメントとして読む。

| 指示 | コメントの 1 行目 |
| --- | --- |
| 別案を選ぶ | `#<PR番号> の「<判断の対象>」は別案 <N>（<案N>）で` |
| 自由記述（形式に合う項目） | `#<PR番号> の「<判断の対象>」について:` |
| 自由記述（形式に合わない項目） | `> <行の本文>`（チェックを除いた行をそのまま引用する） |

- 2 行目以降に補足（自由記述）を続ける。別案を選んだときは補足を省いてよい。自由記述の指示では補足を必須にする
- 別案の番号 `N` は `（別案: …）` の中の並び順で 1 から数える。PR 番号と判断の対象を両方入れ、同じ PR 番号の項目を取り違えないようにする
- 判断の対象・案は行から読んだ文字列をそのまま入れる（`「` `」` を含んでいてもエスケープしない）
- コメントの先頭に `<!-- ask-hub:decision-reply -->` / `<!-- ask-hub:decision-close -->` を置かない（ループの返信と取り違え、指示が処理済みに見える）
- 指示を投稿しても本文のチェックは変えない。ループが指示を処理するときに、該当の行に ` → 変更: …` を追記してチェックを付ける

例:

```text
#319 の「表の区切り」は別案 1（タブ区切り）で
ヘッダー行も同じ区切りにする。
```

### 指示が処理済みかの判定

アプリの詳細画面は、仮決め一覧のコメント（ページングを最後まで追い、古い順（作成順）に並べる）から指示とループの返信の履歴を出す。
処理済みの判定はオーケストレーター（`DecisionLog.unprocessedInstructions`）と同じにする。

- 信用する author が書いた、`<!-- ask-hub:decision-reply -->` か `<!-- ask-hub:decision-close -->` を含むコメントが返信（目印）
- 最後の目印より後にある、信用する author の目印でないコメントが**未処理の指示**。それより前の信用する author のコメントは処理済み
- 信用する author 以外のコメントは指示として扱わず、目印を含んでいても処理済みの判定に使わない

## 信用する author

リポジトリごとに決まる。次のどちらかに当てはまるアカウントを、そのリポジトリで信用する。

1. 設定で列挙したアカウント（アプリは `TrustedAuthors.default`、オーケストレーターは設定の `trustedAuthors`。既定は `mrs1669`）。どのリポジトリでも信用する
2. **そのリポジトリに書き込み権限（write・maintain・admin）を持つアカウント**。REST の `repos/{owner}/{repo}/collaborators?affiliation=all` から求める
   （直接の collaborator・チーム・organization の既定の権限・organization の owner を含む）

共同開発者を加えるときは、GitHub でリポジトリ（またはチーム）に write 以上の権限で招待する。招待そのものを「信用する」という明示的な判断として扱う
（以前は「collaborator から自動で導出しない」としていたが、共同開発者の参加にあたって改めた。ラベルの付け外しとマージにはどのみち write 権限が要るので、
「権限がある人 = 指示として扱ってよい人」とそろえる）。権限はリポジトリごとなので、あるリポジトリの collaborator を、ほかのリポジトリで信用することはない。

- 書き込み権限の一覧は 10 分ごとに取り直す（`RepositoryWriters`）。取得に失敗したら前回の結果、一度も取れていなければ設定の一覧だけを使う
- collaborator の一覧の API はトークンの持ち主に push 権限が要る。権限の無いリポジトリでは、そのアプリは設定の一覧だけを信用する
- オーケストレーターは設定の `trustRepositoryWriters: false` で 2. を止められる（設定の一覧だけを信用する）
- ループには、オーケストレーターが起動ごとにそのリポジトリの信用する author を `ASKHUB_TRUSTED_AUTHORS` で渡す。
  起動スクリプトは epic の準備で playbook に書き、再開のたびに playbook の値を書き直す（epic の途中で招待した人も、次の再開から信用する）

信用する author の書いたものだけを、次の用途に使う。

- 質問の目印（それ以外の author の目印は無視する）
- 回答（それ以外の author の返信は回答とみなさない）
- 新機能の依頼（`idea-request` の Issue）・担当リポジトリの作成・削除の依頼（`repo-request` の Issue）
- 仮決め一覧への指示（それ以外の author のコメントではループを再開しない）
- `ready-for-loop` / `manual-loop` の付いた Discussion・最終 PR・状態用の Issue（それ以外の author が作ったものは扱わない）

## 依頼先のリポジトリ

アプリの「新しい依頼」で依頼先に選べるリポジトリは、**対象の organization（アプリの設定に並べたもの。既定は `shilokuma-inc`）のアーカイブ済みでないリポジトリすべて**とする
（[Discussion #115](https://github.com/shilokuma-inc/ask-hub-apple/discussions/115) の Q4 で確定）。

- 担当 PC（オーケストレーター）のいるリポジトリだけに絞らない。担当 PC がいないリポジトリに出した依頼は、担当が付くまで処理されない
- 一覧は REST の `orgs/{org}/repos` から organization ごとにページングを最後まで追って取得する（`GitHubIdeaRequester`）。並びは設定の順で、organization の中は最近 push された順
- 一覧はアプリに保存したトークンで取得するため、対象を一部のリポジトリに限った Fine-grained PAT では、そのリポジトリしか候補に出ない。
  すべてを出すには、トークンの Repository access を org の全リポジトリにする
- Fine-grained PAT は resource owner を 1 つしか選べない。複数の organization に回答・依頼するなら、すべてに書き込めるトークン（classic PAT など）を使う
- 前に選んだ依頼先は保存しない（Q6）

## リポジトリの作成・削除

アプリから、テンプレートで新しいアプリのリポジトリを作り担当 PC に載せる・担当から外してローカルから消す、を依頼できる。
依頼は `repo-request` の Issue で、本文の**先頭**に機械が読める目印（JSON）を置く（`AskHubKit` の `RepositoryRequest`）。
続けて人が読める表を置く。

```html
<!-- ask-hub:repo-request {"action":"create","appName":"MyQuiz","bundleIdentifier":"jp.shilokuma.MyQuiz","clone":true,"private":false,"repository":"shilokuma-inc/my-quiz-ios","template":"shilokuma-inc/template-quiz-app-ios"} -->
<!-- ask-hub:repo-request {"action":"remove","deleteLocal":true,"force":false,"repository":"shilokuma-inc/notti-ios"} -->
```

| action | 依頼 Issue を作る場所 | キー |
| --- | --- | --- |
| `create` | 作成を任せたい PC の担当リポジトリ（その PC のオーケストレーターが処理する） | `repository`（作るリポジトリ）・`template`（`shilokuma-inc/template-app-ios` か `shilokuma-inc/template-quiz-app-ios` のどちらか）・`appName`（英字で始まる英数字。テンプレートの `scripts/rename.sh` に渡す）・`bundleIdentifier`（省略時は `jp.shilokuma.<appName>`）・`clone`（担当 PC に clone して担当リポジトリに加えるか。`false` なら GitHub に作るだけ。省略時は `true`）・`private`（private で作るか。省略時は `false` = public） |
| `remove` | 担当から外したいリポジトリそのもの | `repository`（Issue のリポジトリと同じであること）・`deleteLocal`（checkout・ループの worktree・DerivedData を消すか）・`force`（未コミット・未 push・stash の確認と、ループの state ファイルの確認をしない） |

- オーケストレーターは、担当リポジトリにある**信用する author**（作った人と、編集した人がいればその人も）の依頼だけを処理する。
  目印が読めない・値が不正な依頼には理由をコメントして、Issue は開いたままにする
- 作成では GitHub に**既定で public** のリポジトリを作り（private では GitHub Actions の実行時間が課金の対象になるため）、名前を変えて `develop` に**直接 push** する。
  App Store Connect でのアプリの作成は Web でしかできないため、新しいリポジトリに `needs-verify` の Issue を立てる（アプリの「実機確認」に出る）
- 削除では GitHub のリポジトリは消さない。ループのプロセスが動いていれば、強制でも外さない。最後の担当リポジトリは外せない
- 処理できたら結果をコメントしてクローズする。処理できなければ理由をコメントする（直したら、その Issue を閉じて依頼し直す）。
  コメントにはローカルのパスを書かない（public のリポジトリでは誰でも読めるため）

## 手動ループ（manual-loop）の担当者

手動ループは、Discussion に `manual-loop` を付け、担当者が自分の Mac の Claude Code で回す。GitHub の Discussion には担当者（Assignees）の欄が無いので、
**担当のコメント**で表す（`AskHubKit` の `ManualLoopAssignment`）。

```html
<!-- ask-hub:manual-assignee login="partner" -->
@partner さんが、この epic を手動ループで回します（AskHub から）。
```

- アプリは、最後の回答を「手動で回す」で投稿するとき、担当者（そのリポジトリに書き込み権限を持つ人。既定は自分）を選ばせ、`manual-loop` を付けた後にこのコメントを付ける。
  @メンションなので、担当者に GitHub の通知が届く。本文には担当者が Claude Code に貼る指示も書く
- 信用する author が書いた担当のコメントのうち、最後のものを担当者とする（担当者を変えるときは、新しいコメントを足す）
- 担当者の Claude Code への指示（`ManualLoopInstruction`）:
  - 開始: `<owner/repo> で Discussion #N の epic を手動ループで回して（scripts/askhub-manual.sh を使う）`
  - 再開: `<owner/repo> の Discussion #N の手動ループを再開して（scripts/askhub-manual.sh resume）`
  - 最終 PR: `<owner/repo> の Discussion #N の手動ループの最終 PR を作って（scripts/askhub-manual.sh final）`
- 受けた Claude は、リポジトリの `scripts/askhub-manual.sh`（テンプレートから引き継ぐ）で準備・起動・状態の書き出し・最終 PR を行う
  （手順は各リポジトリの `.claude/ralph/README.md` の「手で回す（manual-loop）」）
- アプリのステータスタブの「手動ループ」は、開いている手動ループを担当者・状態・最終更新つきで並べ、担当者が自分なら指示のコピーを出す
  （状態が無ければ開始、`completed` なら最終 PR、それ以外は再開）。
  `waitingPullRequests` の `needs-answer` がすべて外れ、ループが止まっていれば「回答がそろいました」と出す
- 手動ループのあるリポジトリでは、オーケストレーターは ask への回答でループを再開しない（ループは担当者の Mac にある。担当者がアプリの知らせを見て再開する）

## 流れ

1. 人間がアプリから新機能を依頼する → `idea-request` の Issue（タイトル `【依頼】<要約>`）
2. オーケストレーターが依頼を検知し、`claude` に質問付きの Discussion を作らせる（`needs-answer`）。
   依頼 Issue には Discussion へのリンクをコメントしてクローズする
3. 人間がアプリで質問に回答する。すべて回答されると、オーケストレーターが `ready-for-loop` を付ける。
   Discussion の最後の未回答の質問では、アプリの回答画面に「投稿したら、回答を確定してループを始める」のトグルが出て、
   オンのまま投稿するとアプリがその場で `ready-for-loop` を付ける（オーケストレーターの次のポーリングを待たない）。
   トグルの初期値は設定画面の「投稿したらループを始める」（初期値オン。UserDefaults に保存）で、回答画面でオフにして投稿することもできる。
   回し方を「手動で回す」にして投稿し `manual-loop` を付けられたら、担当のコメントを付け、画面を閉じずに担当者が Claude Code に渡す 1 行の指示
   （`ManualLoopInstruction`。上記「手動ループ（manual-loop）の担当者」）とコピーのボタンを出す。
   オンのときは投稿の前に確認ダイアログを出す。`ready-for-loop` を付けられなかったときは、回答は投稿済みのまま画面を閉じず、
   エラーと「ループを始める（再試行）」を出す
4. オーケストレーターがループを起動する。ループは子 PR の ask で `needs-answer` を付けることがある
5. ask に回答が付くと、オーケストレーターが終了済みのループを再開し、回答済みの `needs-answer` を外す
6. epic の全タスクが完了すると、オーケストレーターが `develop` 向けの最終 PR（`epic-final`）を作る
7. 人間がアプリの「要対応」の「マージ待ち」から確認して merge commit でマージする
8. マージされると、ワークフローがゴール元の Discussion を解決済みで閉じる（上記「ゴール元の Discussion の目印」）。
   オーケストレーターは epic の仮決め一覧を閉じる（上記「仮決め一覧」）
