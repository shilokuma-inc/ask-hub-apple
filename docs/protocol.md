# AskHub プロトコル

AskHub アプリ・オーケストレーター・ループ（Claude）が、GitHub 上で「人間の判断が必要なもの」を
やり取りするための取り決め。決定の経緯は [Discussion #1](https://github.com/shilokuma-inc/ask-hub-apple/discussions/1) を参照。

このドキュメントで実装済みの仕様を変更するときは、`AskHubKit` の対応する実装も合わせて更新すること。
ラベルは `AskHubLabel`、質問の目印は `QuestionMarker`、回答の形式は `Answer`、
信用する author と回答済みの判定は `TrustedAuthors` が実装している。
「要回答」に出す未回答の質問と「急がない」に出す Issue の取得は `InboxFetcher`（GitHub からの取得は `GitHubInboxSource`）が実装している。

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
| `needs-verify` | Issue | 実機・実データでの確認が必要 | ループ | — （人間が確認して閉じる） |
| `idea-request` | Issue | アプリから出した新機能の依頼 | アプリ | — （オーケストレーターが Discussion を作ってクローズする） |
| `repo-request` | Issue | アプリから出した担当リポジトリの作成・削除の依頼（下記「リポジトリの作成・削除」） | アプリ | — （オーケストレーターが処理して結果をコメントし、クローズする） |
| `epic-final` | PR | epic → `develop` の最終 PR | オーケストレーター | — （アプリからマージする） |
| `askhub-orchestrator` | （リポジトリのラベルとして置くだけ） | このリポジトリを担当する PC のオーケストレーターがいる。説明に最終確認の時刻（Claude の利用上限で待機中なら、解除の時刻も）を書く | オーケストレーター（10 分ごとに説明を書き換える） | — |
| `loop-status` | Issue | ループの状態を書き出す Issue（リポジトリごとに 1 つ。下記「ループの状態」） | オーケストレーター | — |

アプリの一覧での扱い:

- **要回答**: `needs-answer` が付いた Discussion（※1）と PR（※2）
- **急がない**: `decision-log` と `needs-verify` の Issue
- **マージ待ち**: `epic-final` の PR
- **ループ**: 担当リポジトリごとのループの状態。`loop-status` の Issue から読む（下の「ループの状態」）
- **上限で待機中**（ループの先頭）: `askhub-orchestrator` の説明に解除の時刻があるリポジトリ。再開の時刻を出す
- **ループの開始待ち**（ループの先頭。上限で待機中の下）: `ready-for-loop` の Discussion。`askhub-orchestrator` の時刻が 30 分より古い・無いリポジトリは「担当 PC なし」。担当 PC が上限で待機中なら「上限で待機中（〇時に再開）」

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
- 手で回すループ（`manual-loop` の Discussion）は、`writer` を `manual` にして状態・epic・進捗を書き、10 分ごとに `checkedAt` を書き直す。
  書き手が `manual` で `checkedAt` が 30 分以内のあいだ、オーケストレーターは書かない。30 分を過ぎたら、オーケストレーターが書き直す

アプリの読み方（`LoopStatusFetcher`。GitHub からの取得は `GitHubLoopStatusSource`）:

- `organization.repositories` の GraphQL で、リポジトリごとに担当の印（`askhub-orchestrator` の説明）と open な `loop-status` の Issue を一緒に読む（Search API は使わない）。
  リポジトリも Issue もページングを最後まで追う
- 信用する author が作り、目印を読める Issue のうち、最も新しく更新されたものを使う
- 行にするのは、担当の印か信用する author の状態用の Issue があるリポジトリ（Q4: 担当 PC のいるリポジトリをすべて出す）。
  担当の印も `checkedAt` も 30 分より古ければ「担当 PC なし」、担当 PC はいるが状態用の Issue が無ければ「状態なし」とする
- `loop-status` の Issue は「急がない」などの一覧には出さない（一覧はラベルで検索しており、`loop-status` を含めない）

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
アプリの「要回答」に出すのは Discussion（※1）と PR（※2）だけで、`needs-answer` の付いた Issue は一覧に出さない。

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

- 番号は、起動スクリプト（askhub-start-loop）が制御用 worktree に残す `.claude/askhub-bootstrap.local.txt` から読む。手で始めた epic には付かない
- 最終 PR が `develop` にマージされると、ワークフロー（`.github/workflows/close-goal-discussion.yml`）がこの目印を読み、
  Discussion に PR へのリンクをコメントしてから解決済みで閉じる

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
  App Store Connect でのアプリの作成は Web でしかできないため、新しいリポジトリに `needs-verify` の Issue を立てる（アプリの「急がない」に出る）
- 削除では GitHub のリポジトリは消さない。ループのプロセスが動いていれば、強制でも外さない。最後の担当リポジトリは外せない
- 処理できたら結果をコメントしてクローズする。処理できなければ理由をコメントする（直したら、その Issue を閉じて依頼し直す）。
  コメントにはローカルのパスを書かない（public のリポジトリでは誰でも読めるため）

## 流れ

1. 人間がアプリから新機能を依頼する → `idea-request` の Issue（タイトル `【依頼】<要約>`）
2. オーケストレーターが依頼を検知し、`claude` に質問付きの Discussion を作らせる（`needs-answer`）。
   依頼 Issue には Discussion へのリンクをコメントしてクローズする
3. 人間がアプリで質問に回答する。すべて回答されると、オーケストレーターが `ready-for-loop` を付ける。
   Discussion の最後の未回答の質問では、アプリの回答画面に「投稿したら、回答を確定してループを始める」のトグルが出て、
   オンのまま投稿するとアプリがその場で `ready-for-loop` を付ける（オーケストレーターの次のポーリングを待たない）。
   トグルの初期値は設定画面の「投稿したらループを始める」（初期値オン。UserDefaults に保存）で、回答画面でオフにして投稿することもできる。
   回し方を「手動で回す」にして投稿し `manual-loop` を付けられたら、画面を閉じずに Claude Code に渡す 1 行の指示
   （`ManualLoopInstruction`。CLAUDE.md の依頼の形式の末尾に「手動で回して」を付けたもの）とコピーのボタンを出す。
   オンのときは投稿の前に確認ダイアログを出す。`ready-for-loop` を付けられなかったときは、回答は投稿済みのまま画面を閉じず、
   エラーと「ループを始める（再試行）」を出す
4. オーケストレーターがループを起動する。ループは子 PR の ask で `needs-answer` を付けることがある
5. ask に回答が付くと、オーケストレーターが終了済みのループを再開し、回答済みの `needs-answer` を外す
6. epic の全タスクが完了すると、オーケストレーターが `develop` 向けの最終 PR（`epic-final`）を作る
7. 人間がアプリの「マージ待ち」から確認して merge commit でマージする
8. マージされると、ワークフローがゴール元の Discussion を解決済みで閉じる（上記「ゴール元の Discussion の目印」）。
   オーケストレーターは epic の仮決め一覧を閉じる（上記「仮決め一覧」）
