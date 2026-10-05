# オーケストレーター（askhub-orchestrator）

AskHub の回答を受けて、ループ（ralph-loop）を自動で起動・再開する macOS の CLI。
`AskHubKit/Package.swift` の executable ターゲット `askhub-orchestrator` としてビルドする。
アプリは GitHub だけを見るクライアントで、`claude` / `git` / `xcodebuild` の起動はすべてオーケストレーターが行う
（Discussion #1 の Q2）。

> 現時点で行うのは「`ready-for-loop` の Discussion からのループの起動」「ask の回答によるループの再開と `needs-answer` の削除」
> 「epic の完了の検知と最終 PR（`epic-final`）の作成」「仮決め一覧（`decision-log`）のクローズと、指示によるループの再開」
> 「新機能の依頼（`idea-request`）からの質問付き Discussion の作成」。

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
   | state ファイルが現れ、制御用 worktree の準備元（`.claude/askhub-bootstrap.local.txt`）がこの Discussion | ループが始まったとみなし、`ready-for-loop` を外す。外せなければ次のポーリングで外し直す |
   | プロセスが生きている / state ファイルの有無が不明 | 待つ |
   | 開始を確かめられないままプロセスが終わった（別のループの state ファイルが残っていても） | 起動に失敗したとみなし、起動し直す。3 回失敗したら起動をやめる（ラベルは残す） |

4. まだ起動していない Discussion ごとに判定する

   | 条件 | 動作 |
   | --- | --- |
   | 担当リポジトリではない | 何もしない（別の PC の担当） |
   | 起動済みで追跡中 | 何もしない（3. で扱う） |
   | Discussion の author が信用する author ではない | 起動しない（ログに出す） |
   | 起動したプロセスが生きている | 起動しない（終わるのを待つ） |
   | 途中の epic がある（準備を終えた `epic/` のブランチに、回答待ちでない未完了のタスクが残っている） | 起動しない（epic が終わるのを待つ。起動の失敗としては数えない） |
   | 完了した epic の最終 PR を作り終えていない | 起動しない（起動すると前の epic の作業ファイルが退避され、最終 PR を作れなくなる） |
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

オプションで場所を変えたときは、インストーラーが最後に表示する確認と登録のコマンド（`--config` や plist のパスを反映したもの）を使う。

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
  "loopCommand": ["/Users/<ユーザー名>/.local/bin/askhub-start-loop", "{repository}", "{checkoutPath}", "{controlPath}", "{discussion}"]
}
```

`scripts/orchestrator/orchestrator.example.json` をコピーして使う。`loopCommand` は `install.sh` が配置する
`askhub-start-loop`（下記「ループの起動スクリプト」）を絶対パスで指す。

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

## ループの起動スクリプト（askhub-start-loop）

`scripts/orchestrator/start-loop.sh`。`install.sh` が `~/.local/bin/askhub-start-loop` に配置する。
引数は `<repository> <checkoutPath> <controlPath> [discussion]` で、`loopCommand` のプレースホルダをそのまま渡す。

| 呼ばれ方 | 動作 |
| --- | --- |
| `discussion` あり（`ready-for-loop` から） | 新しい epic を準備してからループを起動する。準備はヘッドレスの `claude` が行う（`ralph-setup.sh`・playbook のプレースホルダの置き換え・STEP A に沿った goal の作成・epic の push）。最後の行の `ASKHUB_PROMISE: <完了語>` を読み取る。Discussion はスクリプトが `gh` で取得し、**信用する author の本文・コメント・返信だけ**を `claude` に渡す |
| `discussion` が空（ask への回答で再開） | 既存の制御用 worktree でループを起動し直す。片付け済みのスロットは作り直す。未完了のタスクが無ければ何もしない |
| state ファイルがある | ループが動いているので何もしない。ただし記録した PID（`.claude/askhub-loop.pid`）のプロセスが終わっていれば、残った state を片付けて続ける |

- 前の epic が完了済み（未完了のタスクが無い）なら、制御用 worktree の `.claude/` を `~/Library/Logs/askhub/archive/` に退避してから worktree を片付ける。
  未完了なら新しい epic は始めない（1 リポジトリにつきループは 1 つ）。
  worktree にコミットしていない変更がある・退避に失敗したときは、片付けずに失敗として返す
- 信用する author は、オーケストレーターが設定の `trustedAuthors` を環境変数 `ASKHUB_TRUSTED_AUTHORS` で渡す（手で設定する必要は無い）
- オーケストレーターも PID ファイルを読み、state ファイルが残っていても PID のプロセスが居なければ「止まっている」とみなして再開する
- 準備が途中で失敗した場合（完了語を読み取れない等）は、オーケストレーターの再試行で、同じ Discussion の途中の worktree を片付けてやり直す
- ループは `claude -p --permission-mode bypassPermissions` を `exec` で起動する。このプロセスの寿命がループの寿命になる。
  ralph の Stop hook はヘッドレスでも周回する（標準入力は `/dev/null`）
- ログは `~/Library/Logs/askhub/loops/<リポジトリ>-bootstrap-*.log`（準備）と `<リポジトリ>-loop-*.log`（ループ）
- 環境変数で `claude` の場所・ログの場所・信用する author・準備のモデルを変えられる（スクリプト冒頭のコメントを参照）

## Mac ごとのセットアップ

家の Mac ごとに担当リポジトリを分けて常駐させる（Discussion #1 の Q10）。各 Mac で次を行う。

1. **アカウント**: `claude` にログインする（Mac ごとに別のアカウントでよい）。`gh auth login` は信用する author のアカウントで行う
2. **開発ツール**: Xcode と iOS Simulator のランタイム、`brew install gh jq swiftlint`
3. **共有設定**: `git clone git@github.com:mrs1669/agents-config.git ~/.agents && ~/.agents/install.sh`（AGENTS.md と LEARNINGS の hook）
4. **常駐の前提**: スリープを止める・停電後に自動で起動する・ログインしたままにする（LaunchAgent はログイン中のユーザーで動く）。
   `~/.claude/settings.json` の `skipDangerousModePermissionPrompt` は `true` のまま（無人で `bypassPermissions` を使うため）
5. **ralph-loop プラグイン**: `claude plugin install ralph-loop@claude-plugins-official` を、制御用 worktree（`*-ralph-ctl`）の外で実行する。
   `~/.claude/settings.json` の `enabledPlugins` に入っていれば有効。周回は このプラグインの Stop hook が回すので、無いとループが 1 周で黙って終わる（`askhub-start-loop` は起動前にエラーで止める）
6. **担当リポジトリ**: 設定の `path` に clone する。リポジトリには template-app-ios の ralph 一式（`.claude/ralph/`・`scripts/ralph-*.sh`）とプロトコルのラベルが必要
7. **オーケストレーター**: このリポジトリを clone して `scripts/orchestrator/install.sh` を実行し、
   `~/.config/askhub/orchestrator.json` を `orchestrator.example.json` から作る（担当リポジトリだけを書く。ほかの Mac と重ねない）
8. **確認と登録**: `~/.local/bin/askhub-orchestrator --once` でエラーが出ないことを確かめてから `launchctl bootstrap` する。
   ログは `~/Library/Logs/askhub/orchestrator.log`

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

5. 信用する author の質問がすべて回答済みになった Discussion / PR から `needs-answer` を外す。
   **Discussion の場合は、先に `ready-for-loop` を付ける**（全問回答でループを始める。Discussion #1 の Q3 の変更）。
   付けられなかったときは `needs-answer` も外さず、次のポーリングで再試行する

回答済みの質問はメモリ上でだけ覚えるため、オーケストレーターを再起動した直後は、回答済みの ask が残る PR のリポジトリを 1 回再開しうる。

## 異常終了したループを再開する

ask への回答が無くても、**タスクを残したまま異常終了したループ**は毎回のポーリングで再開する（`StallWatcher`）。
新しい Discussion の起動より先に判定し、途中の epic に別の epic を被せない。

- 異常終了 = 制御用 worktree に `.claude/ralph-loop.local.md` が残っているのに、`.claude/askhub-loop.pid` のプロセスが居ない。
  ralph-loop プラグインが無くて 1 周で終わった・Stop hook が state を見失った・プロセスが落ちた、などで起きる
- `scripts/ralph-stop.sh` で手で止めたループと、promise を出して終わったループは state ファイルが消えるので、再開しない
- 制御用 worktree のブランチが `epic/` で始まるときだけ再開する（`loopCommand` の `{discussion}` は空文字列）
- 起動スクリプトは、前の epic が途中のまま新しい Discussion で起動されたときは、state ファイルを残したまま断る（異常終了の目印を消さない）
- goal / state が変わらないまま 3 回止まったら、自動の再開をやめてログに出す。ループが進めば（goal / state が変われば）数え直す。
  数はメモリ上でだけ覚えるので、オーケストレーターを再起動すると数え直す

## epic が完了したら最終 PR を作る

毎回のポーリングで、`ready-for-loop` の起動判定より前に、担当リポジトリごとに制御用 worktree を読んで判定する（`EpicCompletion`、副作用なし）。
次の Discussion の起動は前の epic の作業ファイルを退避するので、先に最終 PR を作り、作り終えるまで次の Discussion を起動しない。
次をすべて満たしたら epic の完了とみなす。

- ループが止まっている（`.claude/ralph-loop.local.md` が無く、起動したプロセスも生きていない。同じ周回で再開したリポジトリは除く）
- 制御用 worktree のブランチが `epic/` で始まる（`git` を起動せず、`.git` から `HEAD` を読む）
- `.claude/ralph-goal.local.md` に、`※回答待ち` の付いていない `- [ ]` が無い
- `.claude/ralph-state.local.md` の「最終 PR に載せる内容」が埋まっている（HTML コメントだけなら空とみなす）

完了していれば、epic ブランチからリポジトリの既定ブランチ（`develop`）への PR を作り、`epic-final` を付ける。

| 項目 | 値 |
| --- | --- |
| タイトル | `【FEAT】<epic ブランチ> を <既定ブランチ> に取り込む` |
| 本文 | 先頭にゴール元の Discussion（`ゴール元: Discussion #N` と `<!-- ask-hub:discussion N -->`。起動スクリプトの記録がある場合）、続けて「最終 PR に載せる内容」と、オーケストレーターが作った旨・アプリの「マージ待ち」からマージする旨 |
| ラベル | `epic-final` |

最終 PR がマージされると、ワークフロー（`.github/workflows/close-goal-discussion.yml`）が本文の目印からゴール元の Discussion を特定し、
PR へのリンクをコメントしてから解決済みで閉じる（`docs/protocol.md` の「ゴール元の Discussion の目印」）。

同じ head ブランチから既定ブランチへの PR が既にあれば（閉じた PR も含む）作らない（別の base への PR は数えない）。既にある PR が open なら `epic-final` を付け直す
（PR を作った直後にラベルの付与だけ失敗した場合に、次のポーリングで付け直すため。付与は冪等）。
作った PR はメモリ上で覚え、毎回は問い合わせない。
仮決め一覧への指示でループを再開した epic は、再び完了したときに、open な最終 PR の本文を「最終 PR に載せる内容」で書き直す。

## 仮決め一覧を閉じる・指示でループを再開する

毎回のポーリングで、異常終了したループの再開の後に、担当リポジトリの仮決め一覧（`decision-log` の open な Issue）を見る。
epic ブランチはタイトル（`【CHORE】<epic ブランチ> の仮決め一覧`）から読み、そのブランチから既定ブランチへの PR で判定する
（扱いの決まりは `docs/protocol.md` の「仮決め一覧」）。

| 最終 PR | 行うこと |
| --- | --- |
| マージ済み | 閉じるときのコメント（チェックの無い仮決めは既定値のまま確定した旨と一覧）を付けて、完了として閉じる |
| open | ループが止まっていて（state ファイルが無く、異常終了でもない）、制御用 worktree がその epic にあり、未処理の指示があれば、ループを再開する |
| 無い・マージせずに閉じた | 何もしない |

- コメントを付けた後にクローズだけ失敗したときは、次のポーリングでクローズだけをやり直す（コメントの目印で判断する）
- 同じコメントでは 1 回だけ再開する（メモリ上で覚える）。制御用 worktree が別の epic に移っていたら再開せず、ログに 1 回出す


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
