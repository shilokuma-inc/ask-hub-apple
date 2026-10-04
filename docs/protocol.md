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
| `ready-for-loop` | Discussion | 回答が確定し、ループを始めてよい | オーケストレーター（質問がすべて回答されたとき）／アプリ（「回答を確定してループを始める」ボタンで先に始めるとき） | オーケストレーター（ループを起動したとき） |
| `decision-log` | Issue | epic ごとの仮決め一覧（判断ログ） | ループ | — （Issue を閉じて終える） |
| `needs-verify` | Issue | 実機・実データでの確認が必要 | ループ | — （人間が確認して閉じる） |
| `idea-request` | Issue | アプリから出した新機能の依頼 | アプリ | — （オーケストレーターが Discussion を作ってクローズする） |
| `epic-final` | PR | epic → `develop` の最終 PR | オーケストレーター | — （アプリからマージする） |
| `askhub-orchestrator` | （リポジトリのラベルとして置くだけ） | このリポジトリを担当する PC のオーケストレーターがいる。説明に最終確認の時刻を書く | オーケストレーター（10 分ごとに説明を書き換える） | — |

アプリの一覧での扱い:

- **要回答**: `needs-answer` が付いた Discussion（※1）と PR（※2）
- **急がない**: `decision-log` と `needs-verify` の Issue
- **マージ待ち**: `epic-final` の PR
- **ループの開始待ち**（急がないの先頭）: `ready-for-loop` の Discussion。`askhub-orchestrator` の時刻が 30 分より古い・無いリポジトリは「担当 PC なし」

対象は `shilokuma-inc` org 全体で、ラベルで検索する（リポジトリの列挙は設定しない）。

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

## 信用する author

アプリとオーケストレーターの設定で列挙する。既定は `mrs1669`。

信用する author の書いたものだけを、次の用途に使う。

- 質問の目印（それ以外の author の目印は無視する）
- 回答（それ以外の author の返信は回答とみなさない）
- 新機能の依頼（`idea-request` の Issue）

信用リストを collaborator から自動で導出しない。増やす操作は明示的な判断として行う。

## 依頼先のリポジトリ

アプリの「新しい依頼」で依頼先に選べるリポジトリは、**対象の org（`shilokuma-inc`）のアーカイブ済みでないリポジトリすべて**とする
（[Discussion #115](https://github.com/shilokuma-inc/ask-hub-apple/discussions/115) の Q4 で確定）。

- 担当 PC（オーケストレーター）のいるリポジトリだけに絞らない。担当 PC がいないリポジトリに出した依頼は、担当が付くまで処理されない
- 一覧は REST の `orgs/{org}/repos` からページングを最後まで追って取得する（`GitHubIdeaRequester`）
- 前に選んだ依頼先は保存しない（Q6）

## 流れ

1. 人間がアプリから新機能を依頼する → `idea-request` の Issue（タイトル `【依頼】<要約>`）
2. オーケストレーターが依頼を検知し、`claude` に質問付きの Discussion を作らせる（`needs-answer`）。
   依頼 Issue には Discussion へのリンクをコメントしてクローズする
3. 人間がアプリで質問に回答する。すべて回答されると、オーケストレーターが `ready-for-loop` を付ける
   （全問そろう前に始めたいときは、アプリの「回答を確定してループを始める」で付けられる）
4. オーケストレーターがループを起動する。ループは子 PR の ask で `needs-answer` を付けることがある
5. ask に回答が付くと、オーケストレーターが終了済みのループを再開し、回答済みの `needs-answer` を外す
6. epic の全タスクが完了すると、オーケストレーターが `develop` 向けの最終 PR（`epic-final`）を作る
7. 人間がアプリの「マージ待ち」から確認して merge commit でマージする
8. マージされると、ワークフローがゴール元の Discussion を解決済みで閉じる（下記「ゴール元の Discussion の目印」）
