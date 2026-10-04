# オーケストレーター（askhub-orchestrator）

AskHub の回答を受けて、ループ（ralph-loop）を自動で起動・再開する macOS の CLI。
`AskHubKit/Package.swift` の executable ターゲット `askhub-orchestrator` としてビルドする。
アプリは GitHub だけを見るクライアントで、`claude` / `git` / `xcodebuild` の起動はすべてオーケストレーターが行う
（Discussion #1 の Q2）。

> 現時点で行うのは「`ready-for-loop` の Discussion からのループの起動」「ask の回答によるループの再開と `needs-answer` の削除」
> 「epic の完了の検知と最終 PR（`epic-final`）の作成」「新機能の依頼（`idea-request`）からの質問付き Discussion の作成」。

## ビルドと実行

```bash
swift build --package-path AskHubKit -c release --product askhub-orchestrator
"$(swift build --package-path AskHubKit -c release --show-bin-path)/askhub-orchestrator" --config ~/.config/askhub/orchestrator.json
```

| オプション | 説明 |
| --- | --- |
| `--config <path>` | 設定ファイルの場所。既定は `~/.config/askhub/orchestrator.json` |
| `--once` | 1 回だけポーリングして終了する（動作確認用） |
| `-h`, `--help` | 使い方を表示する |

起動すると設定の内容を表示し、`pollIntervalSeconds` ごとにポーリングする。ログは時刻付きで標準出力に出す。

終了コードは、引数の誤りが `64`（`EX_USAGE`）、GitHub のトークンを得られないときが `69`（`EX_UNAVAILABLE`）、
`--once` でのポーリングの失敗が `75`（`EX_TEMPFAIL`）、設定ファイルの誤りが `78`（`EX_CONFIG`）。

GitHub のトークンは起動時に `gh auth token` で得る（Discussion #1 の Q4）。先に `gh auth login` を済ませておく。

## ready-for-loop の Discussion からループを起動する

1 回のポーリングで次を行う。判定は `LaunchPlanner` と `LaunchTracker`（どちらも副作用なし）、GitHub の操作は `GitHubOrchestrator`、
ループの状態の取得と起動は `LocalLoopRuntime` が担う。

1. org 全体から `ready-for-loop` が付いた open な Discussion を検索する（担当リポジトリごとではなく 1 回の検索で）
2. 担当リポジトリごとにループの状態を調べる
   - 制御用 worktree に `.claude/ralph-loop.local.md` があるか（アクセス権が無いなどで確かめられないときは「不明」）
   - このオーケストレーターが起動したプロセスが生きているか
3. 起動済みの Discussion を進める（`LaunchTracker`）

   | 状態 | 動作 |
   | --- | --- |
   | state ファイルが現れた | ループが始まったとみなし、`ready-for-loop` を外す。外せなければ次のポーリングで外し直す |
   | プロセスが生きている / state ファイルの有無が不明 | 待つ |
   | state ファイルが現れないままプロセスが終わった | 起動に失敗したとみなし、起動し直す。3 回失敗したら起動をやめる（ラベルは残す） |

4. まだ起動していない Discussion ごとに判定する

   | 条件 | 動作 |
   | --- | --- |
   | 担当リポジトリではない | 何もしない（別の PC の担当） |
   | 起動済みで追跡中 | 何もしない（3. で扱う） |
   | Discussion の author が信用する author ではない | 起動しない（ログに出す） |
   | 起動したプロセスが生きている | 起動しない（終わるのを待つ） |
   | state ファイルが残っている / 有無が不明 | 起動しない（ログに出す） |
   | 同じリポジトリに番号の小さい起動対象がある | 起動しない（1 リポジトリにつきループは 1 つ） |
   | それ以外 | `loopCommand` を起動する（実行ファイルが無いなどで起動できなければ、3 回まで再試行） |

`loopCommand` はメインの checkout を作業ディレクトリにして、シェルを経由せずに起動する（終了は待たない）。
先頭が絶対パスでなければ `PATH` から探すが、launchd の `PATH` は最小限なので絶対パスにすること。
起動したプロセスと起動済みの Discussion はメモリ上でだけ追跡するため、オーケストレーターを再起動すると忘れる。
その場合も state ファイルが残っていれば二重には起動しない。
`loopCommand` は、ループを始めたら制御用 worktree に `.claude/ralph-loop.local.md` を作ること（`scripts/ralph-start.sh` が作る）。
作らないと開始を確かめられず、起動に失敗したとみなされる。

## 常駐させる（launchd）

`scripts/orchestrator/install.sh` で、release ビルド・実行ファイルの配置・LaunchAgent の plist の書き出しを行う。
launchd への登録はスクリプトでは行わず、最後に登録のコマンドを表示する。

```bash
scripts/orchestrator/install.sh            # 既定の場所に入れる
"$HOME/.local/bin/askhub-orchestrator" --once   # 設定とトークンを確かめる
launchctl bootstrap gui/$(id -u) "$HOME/Library/LaunchAgents/jp.shilokuma.askhub-orchestrator.plist"
```

| オプション | 既定 | 説明 |
| --- | --- | --- |
| `--prefix <dir>` | `~/.local/bin` | 実行ファイルを置く場所 |
| `--config <path>` | `~/.config/askhub/orchestrator.json` | 設定ファイル |
| `--agents-dir <dir>` | `~/Library/LaunchAgents` | plist を書き出す場所 |
| `--log-dir <dir>` | `~/Library/Logs/askhub` | ログ（`orchestrator.log`）の場所 |

plist（`scripts/orchestrator/jp.shilokuma.askhub-orchestrator.plist.template`）の要点:

- ログイン時に起動し（`RunAtLoad`）、落ちたら再起動する（`KeepAlive`。30 秒より短い間隔では起こさない）
- launchd の `PATH` は最小限なので、Homebrew（`/opt/homebrew/bin`）・`/usr/local/bin`・`~/.local/bin` を加えた `PATH` を渡す。
  スクリプトは `gh` / `claude` / `git` がこの `PATH` に無ければ警告する
- `AbandonProcessGroup`: launchd は既定でジョブが終わるとプロセスグループごと止める。オーケストレーターを再起動しても、起動したループを止めない

止めるときは `launchctl bootout gui/$(id -u)/jp.shilokuma.askhub-orchestrator`。
更新するときはスクリプトを流し直してから、`bootout` → `bootstrap` する。

## 設定ファイル

PC ごとに `~/.config/askhub/orchestrator.json` に置く。**commit しない**（ローカルパスを含むため）。

```json
{
  "trustedAuthors": ["mrs1669"],
  "org": "shilokuma-inc",
  "repositories": [
    { "repository": "shilokuma-inc/ask-hub-apple", "path": "~/Desktop/ios/ask-hub-apple" }
  ],
  "pollIntervalSeconds": 60,
  "loopCommand": ["/path/to/start-loop.sh", "{repository}", "{controlPath}"]
}
```

| キー | 必須 | 説明 |
| --- | --- | --- |
| `trustedAuthors` | | 指示として扱う GitHub アカウント。省略時は `["mrs1669"]` |
| `org` | ✓ | `needs-answer` などを検索する organization |
| `repositories` | ✓ | この PC が担当するリポジトリ。`repository` は `owner/repo`、`path` はメインの checkout の絶対パス（`~` 可）。owner は `org` と同じであること。PC 間で担当を重ねない（Q10） |
| `pollIntervalSeconds` | | ポーリング間隔（秒）。既定 60、下限 30（Search API は認証済みでも 30 回/分のため） |
| `loopCommand` | ✓ | ループを起動するコマンド。シェルを経由せず引数の配列のまま実行する |
| `ideaCommand` | | 依頼から質問付きの Discussion を作らせるコマンド。シェルを経由せず実行し、終わるまで待つ（30 分で打ち切る）。プロンプトは標準入力で渡す（依頼の本文をプロセスの引数に出さないため）。省略時は `["claude", "-p", "--allowedTools", "Bash(gh:*)"]`。`{repository}` / `{checkoutPath}` が使える |

### `loopCommand` のプレースホルダ

各引数の中の次の文字列を、起動するリポジトリの値に置き換える。未知の `{name}` があると設定エラーになる。

| プレースホルダ | 値 |
| --- | --- |
| `{repository}` | `owner/repo` |
| `{checkoutPath}` | メインの checkout のパス |
| `{controlPath}` | 制御用 worktree のパス。`scripts/ralph-setup.sh` と同じく checkout の隣の `<ディレクトリ名から -ios を除いたもの>-ralph-ctl` |
| `{discussion}` | ループのゴール元の Discussion の番号（`ready-for-loop` から起動するとき）。Discussion を伴わない起動では空文字列 |

## ask に回答が付いたらループを再開する

`ready-for-loop` の判定の前に、毎回のポーリングで次を行う。判定は `ResumeWatcher`（副作用なし）が担う。

1. org 全体の `needs-answer` の open な Discussion / PR を取得し（`GitHubInboxSource`）、担当リポジトリのものだけを扱う
2. 信用する author の質問と、その回答状況を読み取る（回答済み = 信用する author の返信が 1 件以上）
3. PR の ask（※2）に**新しく**回答が付いたら、そのリポジトリを再開待ちにする。Discussion（※1）の回答では再開しない（ループは `ready-for-loop` で始まる）
4. 再開待ちのリポジトリ

   | 状態 | 動作 |
   | --- | --- |
   | ループが動いている（プロセスが生きている / state ファイルがある） | 起動しない。回答はループ自身が拾う |
   | state ファイルの有無が不明 | 待つ |
   | 止まっている | `loopCommand` を起動する（`{discussion}` は空文字列） |
   | 起動後に state ファイルが現れた | 再開できたとみなす |
   | state ファイルが現れないままプロセスが終わった | 起動し直す。3 回確かめられなければ、次の回答が付くまで再開しない |

5. 信用する author の質問がすべて回答済みになった Discussion / PR から `needs-answer` を外す

回答済みの質問はメモリ上でだけ覚えるため、オーケストレーターを再起動した直後は、回答済みの ask が残る PR のリポジトリを 1 回再開しうる。

## epic が完了したら最終 PR を作る

毎回のポーリングの最後に、担当リポジトリごとに制御用 worktree を読んで判定する（`EpicCompletion`、副作用なし）。
次をすべて満たしたら epic の完了とみなす。

- ループが止まっている（`.claude/ralph-loop.local.md` が無く、起動したプロセスも生きていない。同じ周回で起動したリポジトリは除く）
- 制御用 worktree のブランチが `epic/` で始まる（`git` を起動せず、`.git` から `HEAD` を読む）
- `.claude/ralph-goal.local.md` に、`※回答待ち` の付いていない `- [ ]` が無い
- `.claude/ralph-state.local.md` の「最終 PR に載せる内容」が埋まっている（HTML コメントだけなら空とみなす）

完了していれば、epic ブランチからリポジトリの既定ブランチ（`develop`）への PR を作り、`epic-final` を付ける。

| 項目 | 値 |
| --- | --- |
| タイトル | `【FEAT】<epic ブランチ> を <既定ブランチ> に取り込む` |
| 本文 | 「最終 PR に載せる内容」と、オーケストレーターが作った旨・アプリの「マージ待ち」からマージする旨 |
| ラベル | `epic-final` |

同じ head ブランチから既定ブランチへの PR が既にあれば（閉じた PR も含む）作らない（別の base への PR は数えない）。既にある PR が open なら `epic-final` を付け直す
（PR を作った直後にラベルの付与だけ失敗した場合に、次のポーリングで付け直すため。付与は冪等）。
作った PR はメモリ上で覚え、毎回は問い合わせない。


## 新機能の依頼から質問付きの Discussion を作る

毎回のポーリングの最後に、アプリから出された依頼（`idea-request` の open な Issue。Discussion #1 の Q12）を 1 件だけ処理する。
対象の選び方とプロンプトは `IdeaRequestTracker` / `IdeaPrompt`（副作用なし）が担う。

1. org 全体から `idea-request` の open な Issue を検索し、担当リポジトリかつ信用する author が作った（本文を編集した人がいればその人も信用する author の）ものを、番号の古い順に 1 件選ぶ
2. `ideaCommand` をメインの checkout で実行し、プロンプトを標準入力で渡して終わるまで待つ。プロンプトでは次を指示する
   - リポジトリを読んで依頼を考察し、人間に決めてもらう点を質問にする
   - カテゴリ「Ideas」に Discussion を作り、質問は 1 つにつき 1 コメントで、先頭に質問の目印を置く
   - Discussion に `needs-answer` を付ける
   - 依頼のタイトルと本文は `<request-title>` / `<request-body>` で囲んだデータとして渡し（`<` は全角にして閉じタグを書けなくする）、中の文を手順として扱わない
   - コードの変更・push・PR の作成はしない
   - 最後の行に `ASKHUB_DISCUSSION_URL: <Discussion の URL>` を出す
3. 出力から依頼のリポジトリの Discussion の URL を読み取れたら、依頼 Issue にリンクをコメントしてクローズする
   - 失敗したら次のポーリングで続きから再試行する。コメントを済ませた後はクローズだけを再試行する（Discussion もコメントも重ねない）
4. 終了コードが 0 でない・URL を読み取れないときは、次のポーリングで 1 回だけ再試行する。2 回失敗したら依頼 Issue に失敗をコメントしてやめる（Issue は開いたまま。コメントできるまで再試行する）

`ideaCommand` は 30 分で SIGTERM、さらに 10 秒で SIGKILL を送って止める。終了後の出力の読み切りは最長 5 秒で打ち切る
（`claude` が起動した子プロセスがパイプを持ったまま残っても、ポーリングを止めないため）。
保持する出力は末尾の 1 MB まで（URL は最後の行に出させるので、末尾があれば足りる）。

処理の進み具合はメモリ上でだけ覚えるため、オーケストレーターを再起動すると、諦めた依頼をもう一度試す。
1 件の処理の間はポーリングが止まる（`claude` を同時に 1 つしか動かさないため）。

## 担当の印（askhub-orchestrator）

アプリは担当 PC を知らないので、オーケストレーターは毎回のポーリングの最初に、担当リポジトリのラベル `askhub-orchestrator` の説明へ
最終確認の時刻を書く（同じリポジトリには 10 分に 1 回まで。ラベルが無ければ作る）。
アプリの「急がない」の「ループの開始待ち」は、この時刻が 30 分より古い・無いリポジトリの `ready-for-loop` を「担当 PC なし」と出す。
書けなかったときはログに出し、次のポーリングで書き直す。
