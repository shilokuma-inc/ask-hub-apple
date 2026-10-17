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

1. 担当リポジトリの owner の organization 全体から `ready-for-loop` が付いた open な Discussion を検索する（担当リポジトリごとではなく、`org:a org:b` の 1 回の検索で）
   あわせて `manual-loop` が付いた open な Discussion も 1 回の検索で取る（回答による再開・ループの状態の書き出し・GitHub の情報からの最終 PR で手動ループを見分けるのに使う。
   起動の判定には使わないので、失敗してもログに出して起動は続ける）
2. 担当リポジトリごとにループの状態を調べる
   - 制御用 worktree に `.claude/ralph-loop.local.md` があるか（アクセス権が無いなどで確かめられないときは「不明」）
   - このオーケストレーターが起動したプロセスが生きているか
3. 起動済みの Discussion を進める（`LaunchTracker`）

   | 状態 | 動作 |
   | --- | --- |
   | state ファイルが現れ、制御用 worktree の準備元（`.claude/askhub-bootstrap.local.txt`）がこの Discussion | ループが始まったとみなし、`ready-for-loop` を外す。外せなければ次のポーリングで外し直す |
   | プロセスが生きている / state ファイルの有無が不明 | 待つ |
   | 開始を確かめられないままプロセスが終わった（別のループの state ファイルが残っていても） | 起動に失敗したとみなし、起動し直す。3 回失敗したら起動をやめる（ラベルは残す） |
   | 追跡していないが、制御用 worktree がこの Discussion から準備を終えている（`askhub-bootstrap.local.txt` が一致し、完了語がある） | オーケストレーターの再起動の前に始まったループとみなし、`ready-for-loop` を外す（残すと、epic の後に同じ Discussion からもう一度始めてしまう） |
   | 準備の結果 goal にタスクが無かった（起動スクリプトが `.claude/askhub-no-tasks.local.txt` に番号を残した） | やり直さず、Discussion に「やることが残っていない」とコメントして `ready-for-loop` を外し、目印を消す。追記してラベルを付け直せば、もう一度準備する |

4. まだ起動していない Discussion ごとに判定する

   | 条件 | 動作 |
   | --- | --- |
   | 担当リポジトリではない | 何もしない（別の PC の担当） |
   | 起動済みで追跡中 | 何もしない（3. で扱う） |
   | Discussion の author が信用する author ではない | 起動しない（ログに出す） |
   | `manual-loop` が付いている（手で回す Discussion） | 起動しない（ログに出す）。`ready-for-loop` も外さない（手で回すループが始めるときに外す）。同じリポジトリのほかの Discussion は起動する |
   | 起動したプロセスが生きている | 起動しない（終わるのを待つ） |
   | 途中の epic がある（準備を終えた `epic/` のブランチに、回答待ちでない未完了のタスクが残っている） | 起動しない（epic が終わるのを待つ。起動の失敗としては数えない） |
   | 完了した epic の最終 PR を作り終えていない | 起動しない（起動すると前の epic の作業ファイルが退避され、最終 PR を作れなくなる） |
   | state ファイルが残っている / 有無が不明 | 起動しない（ログに出す） |
   | 同じリポジトリに番号の小さい起動対象がある | 起動しない（1 リポジトリにつき自動ループは 1 つ） |
   | それ以外 | `loopCommand` を起動する（実行ファイルが無いなどで起動できなければ、3 回まで再試行） |

`loopCommand` はメインの checkout を作業ディレクトリにして、シェルを経由せずに起動する（終了は待たない）。
先頭が絶対パスでなければ `PATH` から探すが、launchd の `PATH` は最小限なので絶対パスにすること。
起動したプロセスと起動済みの Discussion はメモリ上でだけ追跡するため、オーケストレーターを再起動すると忘れる。
その場合も state ファイルが残っていれば二重には起動しない。
`loopCommand` は、ループを始めたら制御用 worktree に `.claude/ralph-loop.local.md` を作ること（`scripts/ralph-start.sh` が作る）。
作らないと開始を確かめられず、起動に失敗したとみなされる。

### 手動ループと同時に回す

自動ループは 1 リポジトリにつき 1 つ、手動ループ（`manual-loop` の Discussion）は同じリポジトリでもいくつでも回せる
（[Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425)。Discussion #273 の Q4「1 リポジトリにつきループは 1 つ」を改めた）。
手動ループがあるリポジトリでも、`ready-for-loop` の Discussion から自動ループを起動する。
自動ループの数は、オーケストレーターの制御用 worktree（`<名前>-ralph-ctl`）の state ファイル・プロセス・途中の epic と、同じポーリングで起動した Discussion で数える（手動ループは数えない）。

- 手動ループ（`scripts/askhub-manual.sh`）の作業場所は、ralph-kit 1.4.0 から Discussion ごとに分かれる
  （制御用 worktree `<名前>-ralph-d<番号>-ctl`・スロット `<名前>-ralph-d<番号>-a` / `-b`。PID ファイル `.claude/askhub-loop.pid` もその制御用 worktree に置く）。
  オーケストレーターの制御用 worktree（`<名前>-ralph-ctl`・`-a`・`-b`）と PID ファイルには触らないので、オーケストレーターの Mac でも担当リポジトリの手動ループを `start` して回せる。
  同じ epic は 1 つの worktree でしか checkout できないので、同じ Mac のほかのループが使っている epic 名では、手動ループの `start` も自動ループの準備（`ralph-setup.sh`）も止まる
- kit 1.3 までに `<名前>-ralph-ctl` で始めた手動ループは、移さずにその場所のまま最後まで回る（`resume` / `final` / `status` もそこを使う）。
  このループだけは自動ループと同じ制御用 worktree と PID ファイルを使うので、終わるまでオーケストレーターの Mac では回さない
  （PID ファイルを上書きし合う、手動ループの state ファイル・途中の epic が残って自動ループを起動できない、自動ループの起動が完了した手動ループの epic を退避するなど、自動ループとぶつかる）
- 回答による再開・GitHub の情報からの最終 PR は、制御用 worktree の epic のゴール元が `manual-loop` の Discussion のとき・記録が無いときは、
  この Mac の手動ループ（kit 1.3 までに `<名前>-ralph-ctl` で始めたもの）のものとして自動ループの経路では扱わない（「ask に回答が付いたらループを再開する」「GitHub の情報から最終 PR を作る」）

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
`launchctl kickstart -k` での再起動は使わない。launchd が `state = spawn scheduled` のままプロセスを起動しなくなることがあり（2026-10-06 に発生）、その状態は `bootout` → `bootstrap` でしか直らない。
起動できたかは、ログの `起動しました（pid …）` の行の時刻で確かめる。起動に失敗したときは `終了します（終了コード …）` の行に理由が出る。

## 設定ファイル

PC ごとに `~/.config/askhub/orchestrator.json` に置く。**commit しない**（ローカルパスを含むため）。

```json
{
  "trustedAuthors": ["mrs1669"],
  "repositories": [
    { "repository": "shilokuma-inc/ask-hub-apple", "path": "~/Desktop/ios/ask-hub-apple" },
    { "repository": "BeaconFun4/demomoni-remake-ios", "path": "~/Desktop/ios/demomoni-remake-ios" }
  ],
  "pollIntervalSeconds": 60,
  "loopCommand": ["/Users/<ユーザー名>/.local/bin/askhub-start-loop", "{repository}", "{checkoutPath}", "{controlPath}", "{discussion}"]
}
```

`scripts/orchestrator/orchestrator.example.json` をコピーして使う。`loopCommand` は `install.sh` が配置する
`askhub-start-loop`（下記「ループの起動スクリプト」）を絶対パスで指す。

| キー | 必須 | 説明 |
| --- | --- | --- |
| `trustedAuthors` | | どの担当リポジトリでも指示として扱う GitHub アカウント。省略時は `["mrs1669"]` |
| `trustRepositoryWriters` | | 担当リポジトリに書き込み権限（write 以上）を持つアカウントも、そのリポジトリで指示として扱うか。省略時は `true`（`docs/protocol.md` の「信用する author」） |
| `repositories` | ✓ | この PC が担当するリポジトリ。`repository` は `owner/repo`、`path` はメインの checkout の絶対パス（`~` 可）。owner は別の organization でもよい（`needs-answer` などは、担当リポジトリの owner の organization をまとめて検索する）。PC 間で担当を重ねない（Q10） |
| `pollIntervalSeconds` | | ポーリング間隔（秒）。既定 60、下限 30（Search API は認証済みでも 30 回/分のため） |
| `loopCommand` | ✓ | ループを起動するコマンド。シェルを経由せず引数の配列のまま実行する |
| `ideaCommand` | | 依頼から質問付きの Discussion を作らせるコマンド。シェルを経由せず実行し、終わるまで待つ（30 分で打ち切る）。プロンプトは標準入力で渡す（依頼の本文をプロセスの引数に出さないため）。省略時は `["claude", "-p", "--allowedTools", "Bash(gh:*)"]`。`{repository}` / `{checkoutPath}` が使える |
| `iterationTimeoutMinutes` | | ループの 1 周がこれより長く進まなければ、固まったとみなして止める（分。省略時は 90、10 以上 1440 以下）。下の「固まったループを止める」を参照 |
| `createRepositoryCommand` | | テンプレートからリポジトリを作るコマンド（下記「担当リポジトリの作成・削除」）。省略時は `~/.local/bin/askhub-create-repo`（`install.sh` が置く） |
| `removeRepositoryCommand` | | ローカルの checkout・ループの worktree・DerivedData を消すコマンド。省略時は `~/.local/bin/askhub-remove-repo`（`install.sh` が置く） |
| `newRepositoryDirectory` | | 新しく作ったリポジトリを clone するディレクトリ（`~` 可）。省略時は最初の担当リポジトリの checkout と同じ場所 |
| `conflictCommand` | | epic の最終 PR のコンフリクトを解消させるコマンド（30 分で打ち切る）。省略時は `loopCommand` の実行ファイルと同じ場所の `askhub-resolve-conflict`（`install.sh` が置く）。`{repository}` / `{checkoutPath}` / `{headBranch}` / `{baseBranch}` / `{pullRequest}` が使える |
| `reviewCommand` | | epic の最終 PR に第三者レビューをさせるコマンド（Discussion #503。30 分で打ち切る）。省略時は `loopCommand` の実行ファイルと同じ場所の `askhub-review-final`（`install.sh` が置く）。`{repository}` / `{checkoutPath}` / `{headBranch}` / `{baseBranch}` / `{pullRequest}` / `{headSHA}`（レビューの対象として確認した head）が使える |
| `fixCommand` | | epic の最終 PR の第三者レビューの `要修正` を直させるコマンド（ビルドとテストまで行うので 60 分で打ち切る）。省略時は `loopCommand` の実行ファイルと同じ場所の `askhub-fix-review`（`install.sh` が置く）。使えるプレースホルダは `reviewCommand` と同じ（`{headSHA}` は push の lease に使う） |
| `buildHosts` | | ループのビルドの Mac（xcb）の情報を GitHub に書き出す設定（下の「`buildHosts`」）。**xcb を動かしている Mac のオーケストレーターだけに書く**。省略するとこの機能を止める |
| `model` | | 起動する `claude`（ループ・準備・コンフリクトの解消・最終 PR の第三者レビューと修正・依頼からの Discussion 作成）のモデル。省略時は `claude-opus-5-5`。`opus` などの別名も書ける。環境変数 `ANTHROPIC_MODEL` で渡すので、`ideaCommand` などを書き換えても効く。Discussion でモデルを指定したループ（`docs/protocol.md` の「ループのモデルとエフォート」）はそちらを使う |
| `effort` | | 起動する `claude` のエフォート（`low` / `medium` / `high` / `xhigh` / `max`）。省略時は claude の既定（`auto` を渡し、オーケストレーターの起動元の値は引き継がない）。環境変数 `CLAUDE_CODE_EFFORT_LEVEL` で渡す。Discussion で指定したループはそちらを使う |

以前の設定にあった `org` は不要になった（書いてあっても無視する）。

設定ファイルは**ポーリングのたびに読み直す**。担当リポジトリの追加・削除などは、オーケストレーターを再起動しなくても次のポーリングから効く。
読めないとき（書きかけ・JSON の誤り）はログに 1 回だけ理由を出し、直るまで前の設定のまま動く。
信用する author（設定の `trustedAuthors` と、担当リポジトリへの書き込み権限を持つアカウント）は、ポーリングのはじめに担当リポジトリごとに求め直し（書き込み権限は 10 分ごとに取り直す）、
変わったらログに `<リポジトリ> で信用する author: …` と出す。ループには起動ごとに `ASKHUB_TRUSTED_AUTHORS` で渡す。
アプリからの担当リポジトリの作成・削除の依頼では、オーケストレーターが `repositories` を書き換える（下記）。

### `buildHosts`

```json
"buildHosts": {
  "xcb": "~/.config/askhub/xcodebuild",
  "issueRepository": "shilokuma-inc/ask-hub-apple"
}
```

| キー | 必須 | 説明 |
| --- | --- | --- |
| `xcb` | ✓ | xcb（ループ共通の xcodebuild の入口）の実行ファイルの絶対パス（`~` 可）。`status --json` で load・空きメモリ・コア数・枠を取る |
| `eventsDirectory` | | xcb のイベントログ（`events.jsonl` と、5MB を超えて回した `events.jsonl.1`）のディレクトリ（`~` 可）。省略時は `~/Library/Logs/askhub/xcb`（xcb の `XCB_EVENTS_DIR` の既定と同じ） |
| `issueRepository` | | ビルドの Mac の状態の Issue（ラベル `build-hosts`。`docs/protocol.md` の「ビルドの Mac の状態」）を置くリポジトリ（`owner/repo`）。担当リポジトリのどれかにする。省略したとき・担当から外したときは、その Issue を書かない（各リポジトリの `loop-status` のビルドの情報は書く） |

`issueRepository` が担当リポジトリに無くても設定ファイルは読める（アプリからの依頼で担当から外したときに、設定ごと読めなくならないように）。

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
| `discussion` が空（ask への回答・仮決め一覧や最終 PR への指示・異常終了で再開） | 既存の制御用 worktree でループを起動し直す。片付け済みのスロットは作り直す。未完了のタスクが無ければ何もしない。ただし環境変数 `ASKHUB_RESUME_REASON` が `decision-log`（仮決め一覧への指示による再開）か `final-pr`（最終 PR への指示による再開）のときは、タスクが無くても起動する（指示はループが周回の最初に読んで修正タスクにするため） |
| state ファイルがある | ループが動いているので何もしない。ただし記録した PID（`.claude/askhub-loop.pid`）のプロセスが終わっていれば、残った state を片付けて続ける |

- 前の epic が完了済み（未完了のタスクが無い）なら、制御用 worktree の `.claude/` を `~/Library/Logs/askhub/archive/` に退避してから worktree を片付ける。
  未完了なら新しい epic は始めない（1 リポジトリにつき自動ループは 1 つ）。
  worktree にコミットしていない変更がある・退避に失敗したときは、片付けずに失敗として返す
- 退避先は `~/Library/Logs/askhub/archive/<リポジトリ名>/<時刻>-<epic の / を - にしたもの>/` で、`.claude/` と epic ブランチの名前（`branch.txt`）を置く
- **退避した epic を戻して再開する**: 再開（`discussion` が空）で環境変数 `ASKHUB_RESTORE_EPIC` に epic ブランチがあり、制御用 worktree が別の epic なら、
  今の epic の `.claude/` を上と同じ形で退避して worktree を片付け、戻す epic で制御用 worktree とスロットを作り直して、退避先の `.claude/` を戻してから再開する
  （最終 PR への指示で、制御用 worktree が別の epic に移った後の epic を再開するため。Discussion #498 の Q4）
  - 戻すのは、名前（と `branch.txt`。古い退避には無い）が合い、goal・playbook・完了語が揃っている退避のうち最も新しいもの。戻した退避は消さない
  - 前のループの state・PID・「やることが無い」目印は持ち込まない（state は `ralph-start.sh` が作り直す）
  - 戻す epic の退避が無い・今の epic に未完了のタスクが残っている・今のループが異常終了したまま（state が残っている）・worktree にコミットしていない変更がある・
    origin を取得できない・戻す epic のブランチが無い・戻す epic を別の worktree（手動ループなど）が checkout しているときは、片付ける前に何も変えずに失敗として返す。
    今のループが動いているときは、ほかの再開と同じく何もしない（終了コード 0）
  - 戻す epic のブランチがローカルに無く origin にだけあれば、origin から作ってから作り直す（`ralph-setup.sh` はローカルに無いと既定ブランチから作るため）
  - 制御用 worktree を作り直した後に失敗した（`ralph-setup.sh` の途中など）ときは、**同じ `ASKHUB_RESTORE_EPIC` で呼び直す**と、
    制御用 worktree が戻す epic で完了語と準備の記録が無ければ（テンプレートの作業ファイルしか無ければ）、退避から戻し直す。
    `ASKHUB_RESTORE_EPIC` なしで呼ぶと、完了語の記録が無いので再開できない（オーケストレーターは戻せたことを確かめるまで同じ値で呼び直す）
  - 制御用 worktree がすでにその epic なら、そのまま再開する
  - 今の epic の最終 PR を作り終えたかは見ない（オーケストレーターが確かめてから呼ぶ。下記「最終 PR への指示でループを再開する」）
  - 戻した後、git 管理下の `.claude/` のファイル（`settings.json` など）は退避の古い版ではなく epic の版にする。作り直しの途中で失敗した後の戻し直しでも `ralph-setup.sh` を呼び直す
- 信用する author は、オーケストレーターが起動ごとに環境変数 `ASKHUB_TRUSTED_AUTHORS` で渡す（設定の `trustedAuthors` と、そのリポジトリへの書き込み権限を持つアカウント。手で設定する必要は無い）。
  再開では、制御用 worktree の playbook の「信用する author」もこの値に書き直す
- 再開の理由は、オーケストレーターが起動ごとに環境変数 `ASKHUB_RESUME_REASON` で渡す（仮決め一覧への指示による再開の `decision-log` と、最終 PR への指示による再開の `final-pr`。`loopCommand` に書く必要は無い）
- オーケストレーターも PID ファイルを読み、state ファイルが残っていても PID のプロセスが居なければ「止まっている」とみなして再開する
- 準備が途中で失敗した場合（完了語を読み取れない等）は、オーケストレーターの再試行で、同じ Discussion の途中の worktree を片付けてやり直す
- 再開（`discussion` が空）では、前のループの state ファイルをループの起動の直前まで残す（その間は起動スクリプト自身の PID を記録し、
  state の時刻を更新する）。`ralph-setup.sh` などが一時的なエラーで落ちても state が残るので、オーケストレーターは異常終了として再試行する
  （先に消していたころは「タスクを残して止まっている」＝開始待ちに見え、再試行されずに止まったままになっていた）
- **モデルとエフォート**: 新しい epic の準備では、Discussion の信用する author のコメントからモデルとエフォートの目印（`ask-hub:loop-options`。`docs/protocol.md` の「ループのモデルとエフォート」）を読み、
  準備とループ本体の `claude` に `--model` / `--effort` で渡す。読んだ値は制御用 worktree の `.claude/askhub-loop-options.local.txt` に残し、再開でも同じ値を使う。
  目印が無い・値が不正なとき（`--model` に渡せない形、知らないエフォート）は使わず、オーケストレーターが渡す設定の `model` / `effort`（環境変数）に任せる。
  使うモデルとエフォートは、準備と再開のときにログに出す。`ASKHUB_BOOTSTRAP_MODEL` を設定すると、準備のモデルだけをそれにする
- ループは `claude -p --permission-mode bypassPermissions` を `exec` で起動する。このプロセスの寿命がループの寿命になる。
  ralph の Stop hook はヘッドレスでも周回する（標準入力は `/dev/null`）
- ログは `~/Library/Logs/askhub/loops/<リポジトリ>-bootstrap-*.log`（準備）と `<リポジトリ>-loop-*.log`（ループ）
- 環境変数で `claude` の場所・ログの場所・信用する author・準備のモデルを変えられる（スクリプト冒頭のコメントを参照）
- **xcodebuild のラッパー**: 環境変数 `ASKHUB_XCODEBUILD_WRAPPER`、または `~/.config/askhub/xcodebuild`（実行可能なとき）に
  ラッパーを置くと、新しい epic の準備で playbook の検証コマンドを `<ラッパー> "$PWD" <xcodebuild の引数…>` の形で書かせ、
  「このアプリ固有の前提」にも同じ規則を入れさせる。ラッパーは第 1 引数に作業ツリーのパスを取り、残りを xcodebuild にそのまま渡し、
  終了コードを返すこと。Simulator（`name=` 指定）と DerivedData の作業ツリーごとの分離もラッパーが受け持つ
  （例: ビルド専用機へ ssh で回す・同時実行数を絞る）。置かなければ従来どおり、UDID の `id=` とスロットごとの `-derivedDataPath` で書かせる。
  既存の epic の playbook は作り直さないので、変えるときは手で書き換える。
  このリポジトリの xcb（下の「xcb」）がこのラッパーの実装で、終了コード 75（テストを動かせる Mac が無いので流していない）を
  テスト未実施として扱い、PR の CI のテストで確かめる規則も playbook に書かせる

## Mac ごとのセットアップ

家の Mac ごとに担当リポジトリを分けて常駐させる（Discussion #1 の Q10）。各 Mac で次を行う。

1. **アカウント**: `claude` にログインする（Mac ごとに別のアカウントでよい）。`gh auth login` は信用する author のアカウントで行う
2. **開発ツール**: Xcode と iOS Simulator のランタイム、`brew install gh jq swiftlint`
3. **共有設定**: `git clone git@github.com:mrs1669/agents-config.git ~/.agents && ~/.agents/install.sh`（AGENTS.md と LEARNINGS の hook）
4. **常駐の前提**: スリープを止める・停電後に自動で起動する・ログインしたままにする（LaunchAgent はログイン中のユーザーで動く）。
   `~/.claude/settings.json` の `skipDangerousModePermissionPrompt` は `true` のまま（無人で `bypassPermissions` を使うため）
5. **ralph-loop プラグイン**: `claude plugin install ralph-loop@claude-plugins-official` を、制御用 worktree（`*-ralph-ctl`・手動ループの `*-ralph-d<番号>-ctl`）の外で実行する。
   `~/.claude/settings.json` の `enabledPlugins` に入っていれば有効。周回は このプラグインの Stop hook が回すので、無いとループが 1 周で黙って終わる（`askhub-start-loop` は起動前にエラーで止める）
6. **担当リポジトリ**: 設定の `path` に clone する。リポジトリには ralph-kit の中継（`scripts/ralph-*.sh`。[ralph-kit](https://github.com/shilokuma-inc/ralph-kit) の `install.sh` で入れる）とプロトコルのラベルが必要
7. **オーケストレーター**: このリポジトリを clone して `scripts/orchestrator/install.sh` を実行し、
   `~/.config/askhub/orchestrator.json` を `orchestrator.example.json` から作る（担当リポジトリだけを書く。ほかの Mac と重ねない）
8. **確認と登録**: `~/.local/bin/askhub-orchestrator --once` でエラーが出ないことを確かめてから `launchctl bootstrap` する。
   ログは `~/Library/Logs/askhub/orchestrator.log`

## xcb（ループの xcodebuild を空いている Mac に振り分ける）

`scripts/orchestrator/xcb`（zsh）。`install.sh` が `~/.local/bin/askhub-xcb` に配置する。
ループを動かす Mac（振り分け元）で xcodebuild を受け、ssh でつながる Mac のうち最も空いている Mac で実行して、出力と終了コードをそのまま返す。
上の「xcodebuild のラッパー」として使う。

### 有効にする

振り分け元の Mac で次を行う。置くだけでは使われない（`~/.config/askhub/xcodebuild` があるときだけ、新しい epic の playbook が xcb 経由になる）。

```bash
ln -s ~/.local/bin/askhub-xcb ~/.config/askhub/xcodebuild
mkdir -p ~/.config/xcb && cp scripts/orchestrator/xcb-hosts.example ~/.config/xcb/hosts   # ビルド先を書き換える
~/.local/bin/askhub-xcb status
```

- ビルド先の Mac には、振り分け元から鍵で ssh で入れるようにしておく（`BatchMode=yes` で入れること）。Xcode と Simulator のランタイムも入れておく
- 振り分け元の Mac は「リモートログイン」を有効にし、22 番ポートで接続を受けるようにしておく。ビルド先の見張りは、振り分け元の 22 番ポートに届くかで
  ネットワークから外れたことに気づく。受けない設定でもビルドはできるが、そのときは ssh のセッションが消えたときにしか止まらない
- 以前の配置（スクリプトの隣の `.xcb-state`・`.xcb-locks`・`xcb.log`、ビルド先の `~/remote-builds`）は使わなくなる。
  xcb が動いていないときに、外した Mac の記録（`.xcb-state/drain/`）だけ新しい状態の置き場へ移し、ビルド先の `~/remote-builds` は消してよい

### ビルド先の設定（`~/.config/xcb/hosts`）

1 行 1 台で `<ssh の Host 名> <同時実行の上限> <優先度> <Xcode の Developer ディレクトリ> <テストを受けるか>`。例は `scripts/orchestrator/xcb-hosts.example`。

| 列 | 説明 |
| --- | --- |
| 優先度 | 空き具合に掛ける重み（大きいほど選ばれやすい）。行を消すかコメントにすれば候補から外れる |
| Xcode の Developer ディレクトリ | `-` ならその Mac の `xcode-select` のまま |
| テストを受けるか | `test`（省略時。すべて受ける）/ `nosimtest`（Simulator のテストだけ受けない。macOS のテストとビルドは受ける）/ `notest`（ビルドだけ） |

`local` の行は振り分け元の Mac 自身。優先度が 0（省略時）なら、リモートが 1 台もつながらないときだけ使う。
0 より大きくすると、空きメモリが `XCB_LOCAL_MIN_FREE_MEMORY`（既定 50%）以上で、load ÷ コア数が `XCB_LOCAL_MAX_LOAD`（既定 0.5）以下のときだけ、リモートと並べて選ぶ。
ループの Claude も動く Mac なので、混んでいるときには回さない。

### 振り分けの規則

- **選び方**: 空き具合 = 優先度 × 空きメモリの割合 × (コア数 − load average) ÷ (1 + その Mac で実行中の本数) が最大の Mac。
  リモートは ssh で問い合わせ、結果を 15 秒使い回す。枠は振り分け元の mkdir ロックで、すべてのループ・スロットで共有する。満杯なら空くまで待つ
- **テスト**: test 系の action（`test` / `test-without-building`）は、その種類のテストを受ける Mac にだけ回す。
  受けられる Mac が 1 台もつながっていなければ（持ち出し中など）、**待たずに終了コード 75 で返す**（テストの失敗ではない）。
  出力で、テスト未実施として PR を出し CI のテストで確かめるようループに伝える。待たせたいときは `XCB_TEST_WAIT`（秒）を指定する
- **`build-for-testing` → `test-without-building`**: DerivedData は Mac ごとなので、`build-for-testing` を実行した Mac を作業ツリーとプラットフォームごとに覚え、
  `test-without-building` はその Mac に回す。記録が無い・その Mac で流せない（テストを受けない・つながらない・外している）ときは、
  `test`（ビルドしてからテスト）に置き換えて流せる Mac でやり直す（`-xctestrun` を渡したときは置き換えない）。
  ビルドし直しを減らすため、`build-for-testing` は続くテストを受けられる Mac に優先して回す（1 台もつながっていなければ、ほかの Mac でビルドだけ確かめる）
- **署名**: ssh 越しではログインのキーチェーンを使えず、macOS の署名が `errSecInternalComponent` で失敗する。
  macOS 宛てのビルド・テストで署名の指定（`CODE_SIGN…`）が無ければ、アドホック署名の設定を足す（archive は除く。CI の macOS のテストと同じ）
- **Simulator**: リモートでは `platform=iOS Simulator,name=…` を作業ツリー専用の Simulator（`xcb-<作業ツリー>-<機種>-<ランタイム>`。無ければ作る）に置き換える。
  ランタイムはその Xcode の SDK と同じか古いもののうち最新
- **置き場**: リモートは `~/remote-builds.noindex/src/<作業ツリー>`（rsync で同期。`.git`・DerivedData・`.build` は送らない）と
  `~/remote-builds.noindex/dd/<作業ツリー>`（DerivedData。ループが付けた `-derivedDataPath` は使わない）。
  名前を `.noindex` で終わらせて Spotlight の索引から外す（ビルドのたびに索引を作り直して load が上がり、選ばれにくくなるため）。`XCB_REMOTE_ROOT` で変えられる。
  `local` は `~/Library/Developer/Xcode/DerivedData/xcb-<作業ツリー>`
- **切断**: ssh の生存確認（5 秒ごと × 3 回）で切断に気づいたら、その Mac を 60 秒候補から外し、別の Mac で最初からやり直す（最大 4 回）。
  リモート側の見張りが、ssh のセッションが消えるか、振り分け元の 22 番ポートに一度つながった後に 15 秒届かなければ xcodebuild を止める
- **プラットフォーム**: visionOS などのプラットフォームが入っていない Mac に当たったら、1 時間そのプラットフォームの候補から外して別の Mac でやり直す

### コマンドと状態

| コマンド | 説明 |
| --- | --- |
| `askhub-xcb <作業ツリー> <xcodebuild の引数…>` | ビルド・テストを振り分けて実行する |
| `askhub-xcb status [--json]` | 各 Mac の状態・load・空きメモリ・実行中の本数。`--json` はオーケストレーター向け。`local` の `state` は `standby`（外していれば `drained`）。`local` にもコア数・load・空きメモリを載せる |
| `askhub-xcb drain <Host>` / `undrain <Host>` | その Mac を候補から外す / 戻す（実行中のものは止めない。`local` も指定できる） |

| 置き場 | 内容 |
| --- | --- |
| `~/.local/state/askhub/xcb`（`XCB_STATE_DIR`） | 問い合わせの結果・外した Mac・実行中のビルド・枠のロック・`build-for-testing` を実行した Mac |
| `~/Library/Logs/askhub/xcb/events.jsonl`（`XCB_EVENTS_DIR`） | イベント（1 行 1 JSON。5MB を超えたら `.1` に回す）。オーケストレーターが読む |
| `~/Library/Logs/askhub/xcb/xcb.log`（`XCB_LOG`） | 1 回の実行ごとに、実行した Mac・所要時間・終了コード |

## ask に回答が付いたらループを再開する

`ready-for-loop` の判定の前に、毎回のポーリングで次を行う。判定は `ResumeWatcher`（副作用なし）が担う。

1. 担当リポジトリの owner の organization 全体から `needs-answer` の open な Discussion / PR を取得し（`GitHubInboxSource`）、担当リポジトリのものだけを扱う
2. 信用する author の質問と、その回答状況を読み取る（回答済み = 信用する author の返信が 1 件以上）
3. PR の ask（※2）に**新しく**回答が付き、その PR の base がこの PC の自動ループの epic（制御用 worktree のブランチ）なら、そのリポジトリを再開待ちにする。
   Discussion（※1）の回答では再開しない（ループは `ready-for-loop` で始まる）。
   同じリポジトリで自動ループと手動ループが回るので、ほかの epic（手動ループ・`develop` など）宛ての PR の回答では再開しない
   （[Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425)）。PR の base は `needs-answer` の検索で一緒に取る（`baseRefName`。検索の回数は増やさない）
4. 再開待ちのリポジトリ

   | 状態 | 動作 |
   | --- | --- |
   | 途中の epic が無い（準備を終えた `epic/` のブランチに、回答待ちでない未完了のタスクが無い） | 起動しない。再開待ちをやめ（諦めた記録も消す）、ログに出す。起動スクリプトも「未完了のタスクがありません」で断るので、起動しても state ファイルが現れないまま終わり、ループは落ちていないのに「異常終了（再開を諦めた）」になってしまうため |
   | ループが動いている（プロセスが生きている / state ファイルがある） | 起動しない。回答はループ自身が拾う |
   | state ファイルの有無が不明 | 待つ |
   | 止まっている | `loopCommand` を起動する（`{discussion}` は空文字列） |
   | 起動後に state ファイルが現れた | 再開できたとみなす |
   | state ファイルが現れないままプロセスが終わった | 起動し直す。3 回確かめられなければ、次の回答が付くまで再開しない |

5. 信用する author の質問がすべて回答済みになった Discussion / PR から `needs-answer` を外す。
   **Discussion の場合は、先に `ready-for-loop` を付ける**（全問回答でループを始める。Discussion #1 の Q3 の変更）。
   付けられなかったときは `needs-answer` も外さず、次のポーリングで再試行する
   ただし、信用する author の Discussion に `manual-loop` が付いていれば（手で回す Discussion）、`ready-for-loop` は付けずに
   `needs-answer` だけを外す（ログに「manual-loop（手で回す）なので、ready-for-loop は付けません」と出す）。
   `manual-loop` と author は `needs-answer` の検索結果から読む。信用外の author の Discussion に付いた `manual-loop` は無視し、今までどおり扱う
6. 信用する author の open な `manual-loop` の Discussion があるリポジトリ（手動ループ）では、手動ループの epic 宛ての PR の回答で再開待ちにしない。
   ループは担当者の Mac で動いているので、担当者がアプリの「回答がそろいました」を見て再開する。
   手動ループのあるリポジトリでは、次のときも自動ループの epic とみなさない（kit 1.3 までに始めた手動ループは、この PC の制御用 worktree を使っていることがあるため。
   kit 1.4.0 から始めた手動ループは `<名前>-ralph-d<番号>-ctl` を使い、制御用 worktree には現れない）。このとき、そのリポジトリの再開待ちもやめる
   - 制御用 worktree の epic のゴール元（起動スクリプトの記録）が `manual-loop` の Discussion
   - ゴール元の記録が無い（手で始めた epic）

   そのポーリングで `manual-loop` の Discussion を取得できなかったときは、ゴール元の記録がある epic を自動ループの epic とみなす
   （ゴール元を記録するのは自動ループの起動スクリプトだけ。取得の失敗で見送ると、その回に付いた回答を処理済みにしてしまい再開できなくなる）。
   base が分からない PR（base を埋めない取得元から来たもの。GitHub の検索では必ず取れる）は、手動ループの無いリポジトリでだけ今までどおり再開待ちにする

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
| 本文 | 先頭にゴール元の Discussion（`ゴール元: Discussion #N` と `<!-- ask-hub:discussion N -->`。起動スクリプトの記録がある場合）、続けて「最終 PR に載せる内容」と、オーケストレーターが作った旨・アプリの「要対応」の「マージ待ち」からマージする旨 |
| ラベル | `epic-final` |

最終 PR がマージされると、ワークフロー（`.github/workflows/close-goal-discussion.yml`）が本文の目印からゴール元の Discussion を特定し、
PR へのリンクをコメントしてから解決済みで閉じる（`docs/protocol.md` の「ゴール元の Discussion の目印」）。

同じ head ブランチから既定ブランチへの PR が既にあれば（閉じた PR も含む）作らない（別の base への PR は数えない）。既にある PR が open なら `epic-final` を付け直す
（PR を作った直後にラベルの付与だけ失敗した場合に、次のポーリングで付け直すため。付与は冪等）。
作った PR はメモリ上で覚え、毎回は問い合わせない。
仮決め一覧への指示でループを再開した epic は、再び完了したときに、open な最終 PR の本文を「最終 PR に載せる内容」で書き直す（ループの開始を確かめた場合だけ。下記「仮決め一覧を閉じる・指示でループを再開する」）。

## 仮決め一覧を閉じる・指示でループを再開する

毎回のポーリングで、異常終了したループの再開の後に、担当リポジトリの仮決め一覧（`decision-log` の open な Issue）を見る。
epic ブランチはタイトル（`【CHORE】<epic ブランチ> の仮決め一覧`）から読み、そのブランチから既定ブランチへの PR で判定する
（扱いの決まりは `docs/protocol.md` の「仮決め一覧」）。

| 最終 PR | 行うこと |
| --- | --- |
| マージ済み | 閉じるときのコメント（チェックの無い仮決めは既定値のまま確定した旨と一覧）を付けて、完了として閉じる |
| open | ループが止まっていて（state ファイルが無く、異常終了でもない）、制御用 worktree がその epic にあり、未処理の指示があれば、ループを再開する（下記） |
| 無い・マージせずに閉じた | 何もしない |

- コメントを付けた後にクローズだけ失敗したときは、次のポーリングでクローズだけをやり直す（コメントの目印で判断する）
- 同じコメントでは 1 回だけ再開する（メモリ上で覚える）。制御用 worktree が別の epic に移っていたら再開せず、ログに 1 回出す
- 再開では `loopCommand` に環境変数 `ASKHUB_RESUME_REASON=decision-log` を足して起動する。epic のタスクがすべて完了していても、
  起動スクリプトがループを起動する（指示はループが周回の最初に読んで修正タスクにする）。
  起動スクリプトは担当リポジトリの `scripts/ralph-start.sh` にも同じ値を渡し、`ralph-start.sh` は `decision-log` のときだけ
  未完了タスクが 0 件でも state を作る。担当リポジトリの `ralph-start.sh` がこれに対応していないと、タスク 0 件の再開は失敗する
- 起動した後は、ループの開始を確かめてから、そのコメントを処理済みとして覚え、最終 PR の本文の書き直しの対象にする

  | 起動した後の状態 | 動作 |
  | --- | --- |
  | プロセスが生きている / state ファイルの有無が不明 | 待つ |
  | state ファイルが現れた | 開始を確かめた |
  | state ファイルが現れないままプロセスが終わり、その間にループが指示へ返信している | 開始を確かめた（ポーリングの間に始まって終わった） |
  | state ファイルが現れないままプロセスが終わり、指示が未処理のまま | 最終 PR は書き直さず、起動し直す。3 回確かめられなければ、そのコメントでは再開しない（新しい指示が付けば、また再開する） |


## 最終 PR への指示でループを再開する

仮決め一覧の後に、担当リポジトリの open な `epic-final` の PR（信用する author が作ったもの）のコメントを見る
（ページングを最後まで追う。扱いの決まりは `docs/protocol.md` の「最終 PR への指示」）。仮決め一覧が無い epic でも、最終 PR に付いた指摘を人間の指示で直させるため。

- 信用する author の、最後のループの返信（`<!-- ask-hub:final-reply -->`）より後のコメントのうち、目印の無いものが未処理の指示。
  CodeRabbit を含む信用しない author のコメント・オーケストレーターのコメント（`<!-- ask-hub:orchestrator -->` と、目印を付ける前の `（askhub-orchestrator）` で終わるもの）・
  `@coderabbitai` で始まる CodeRabbit への依頼では再開しない
- ループが止まっていて（state ファイルが無く、異常終了でもない）、制御用 worktree がその PR の epic（head のブランチ）にあり、未処理の指示があれば、ループを再開する
- **制御用 worktree が別の epic に移っていたら**（Discussion #498 の Q4）、その epic の作業ファイルを退避から戻して再開する。自動ループの制御用 worktree はリポジトリに 1 つなので、
  次がそろうまで待つ（失敗ではない。処理済みにせず、毎回のポーリングで確かめ直す。待っていることはログに 1 回出す）
  - 制御用 worktree のループが止まっている（動いている・異常終了したループは、ほかの再開と同じく先に終わらせる）
  - 制御用 worktree の epic の最終 PR を作り終えている（既定ブランチへの PR がある。未完了の epic は退避しない）
  - 制御用 worktree を手動ループ（kit 1.3 まで）が使っていない
  - 制御用 worktree の epic を指示で再開した後なら、再び完了して最終 PR の本文を書き直し終えている（まとめが退避先に移らないように。タスクを残したまま止まったときも待つ）

  そろったら `ASKHUB_RESTORE_EPIC=<指示の epic>` を足して起動する。起動スクリプトが今の epic を退避し、指示の epic の作業ファイルを戻してから再開する（上記「ループの起動スクリプト」）。
  起動スクリプトが戻せずに終わったら（退避が無い・作り直しの途中で失敗したなど）、制御用 worktree がすでに指示の epic に切り替わっていても、同じ値で呼び直す（開始を確かめられなければ 3 回まで）。
  指示の最終 PR の本文のゴール元の Discussion が手動ループのものなら、戻さずにログに 1 回出す（担当者が再開する）
- 再開の進め方（同じコメントでは 1 回だけ・開始の確かめ方・3 回まで・再び完了したら最終 PR の本文を書き直す）は、
  上記の仮決め一覧と同じ。仮決め一覧と最終 PR の両方に指示があっても、1 回のポーリングで起動するループは 1 つ
- 再開では `loopCommand` に環境変数 `ASKHUB_RESUME_REASON=final-pr` を足して起動する。起動スクリプトは `decision-log` と同じく、タスクが 0 件でも起動する。
  `scripts/ralph-start.sh`（ralph-kit 1.4.0 時点）は 0 件の起動を `decision-log` でしか許さないので、起動スクリプトは `final-pr` を `decision-log` として渡す
- 手動ループの epic（kit 1.3 までの手動ループが、この PC の制御用 worktree を使っている場合）は再開しない（ログに 1 回出す）。手動ループは担当者が再開する。
  仮決め一覧への指示でも同じ。`manual-loop` の Discussion を取得できなかったポーリングでは、手動ループの epic かを決められないので、再開を見送って次のポーリングで確かめ直す
- ループが動いている・異常終了したリポジトリでは、開始を確かめる記録が無ければ最終 PR の一覧を取らない（ポーリングごとの API 呼び出しを減らす）
- ループは指示を読み、指した CodeRabbit の指摘をデータとして読んで修正タスクにし、指示に `<!-- ask-hub:final-reply -->` 付きで返信する。
  これは ralph-kit の playbook の手順で、**playbook が最終 PR への指示を読むようになるまでは、再開してもループは指示を処理しない**
  （仮決め一覧と最終 PR の両方に指示があるときも、ループが返信するまでは、それぞれの指示で 1 回ずつ起動する）

## 新機能の依頼から質問付きの Discussion を作る

毎回のポーリングの最後に、アプリから出された依頼（`idea-request` の open な Issue。Discussion #1 の Q12）を 1 件だけ処理する。
対象の選び方とプロンプトは `IdeaRequestTracker` / `IdeaPrompt`（副作用なし）が担う。

1. 担当リポジトリの owner の organization 全体から `idea-request` の open な Issue を検索し、担当リポジトリかつ信用する author が作った（本文を編集した人がいればその人も信用する author の）ものを、番号の古い順に 1 件選ぶ
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

## 担当リポジトリの作成・削除

アプリから出した `repo-request` の Issue（形式は `docs/protocol.md` の「リポジトリの作成・削除」）を、毎回のポーリングで 1 件ずつ処理する。
担当リポジトリにある、信用する author の依頼だけを対象にする。

**作成**（`createRepositoryCommand`。既定は `scripts/orchestrator/create-repo.sh`）:

1. 末尾に `<テンプレート> <owner/repo> <アプリ名> <Bundle ID> <checkout のパス> <public|private>` を足して実行する（30 分で打ち切る）。
   checkout のパスは `newRepositoryDirectory/<リポジトリ名>`。GitHub に作るだけの依頼では空文字列
2. スクリプトは、テンプレートからリポジトリを作り（依頼の `private` が `true` でなければ public）、clone して `scripts/rename.sh` でアプリ名を変え、
   `Configs/Project.xcconfig` の `APP_BUNDLE_IDENTIFIER` を書いて `develop` に直接 push する。
   AskHub のラベルを作り、App Store Connect への登録を `needs-verify` の Issue にする。
   途中で失敗しても、やり直すと続きから進む（テンプレートから作った同名のリポジトリ・同じ origin の checkout は使い回す）
3. 成功したら、clone した場合は設定ファイルの `repositories` に加える（元のファイルは `orchestrator.json.bak` に写す）。
   次のポーリングを待たずに担当リポジトリとして扱う

**削除**:

1. ループのプロセスが動いていれば外さない。最終 PR のコンフリクトを裏で解消している間も外さない（解消はメインの checkout に一時 worktree を作るため）。
   制御用 worktree に state ファイルが残っていれば、強制の依頼でなければ外さない
2. ローカルも消す依頼なら、`removeRepositoryCommand`（既定は `scripts/orchestrator/remove-repo.sh`）に
   `[--force] <checkout のパス> <制御用 worktree のパス>` を足して実行する。ループの worktree には、オーケストレーターの `<名前>-ralph-ctl`・`-a`・`-b` に加えて、
   この Mac の手動ループの `<名前>-ralph-d<番号>-ctl`・`-a`・`-b`（ralph-kit 1.4.0 から）も含める。手動ループのプロセスが動いていれば、強制でも消さない。
   スクリプトは、強制でなければ
   未コミットの変更（ループの作業ファイル `.claude/askhub-*`・`.claude/ralph-*.local.*` は除く）・stash・どのリモートにも無いコミットを持つブランチがないかを確かめる。
   ブランチは、既定ブランチに取り込んでも木が変わらなければ（squash merge 済みなど）消してよいものとして扱う。
   checkout やループの worktree が git の作業ツリーとして読めない・確かめるための git が失敗したときも、確かめられないので消さない。
   消してよければ、制御用 worktree の `.claude/` を `~/Library/Logs/askhub/archive/<名前>/removed-<日時>/`（手動ループの制御用 worktree は、その下の制御用 worktree の名前のディレクトリ）に退避してから、
   checkout・ループの worktree・checkout の隣の DerivedData（`<名前>-ralph-dd*` など）・Xcode の既定の DerivedData のうちそのプロジェクトのものを消す
3. 設定ファイルの `repositories` から外し、担当の印（`askhub-orchestrator` のラベル）を消す（アプリで「担当 PC なし」になる）

スクリプトは人に伝える行を `ASKHUB_RESULT: …`、失敗の理由を `ASKHUB_ERROR: …` で出す。依頼 Issue にはこの行だけを書き、ほかの出力はログにだけ残す。
前提を満たさない（既に同名のリポジトリがある・未 push の変更がある など）ときは終了コード 3 で終わり、やり直さずに理由をコメントする。
それ以外の失敗は 1 回だけやり直し、それでも失敗したら理由をコメントする。

## 担当の印（askhub-orchestrator）

アプリは担当 PC を知らないので、オーケストレーターは毎回のポーリングの最初に、担当リポジトリのラベル `askhub-orchestrator` の説明へ
最終確認の時刻を書く（同じリポジトリには 10 分に 1 回まで。ラベルが無ければ作る）。
アプリの「ステータス」タブの「ループの開始待ち」は、この時刻が 30 分より古い・無いリポジトリの `ready-for-loop` を「担当 PC なし」と出す。
書けなかったときはログに出し、次のポーリングで書き直す。
利用上限で待機している間は、説明の末尾に `・上限で待機中: <解除の時刻>` を足す（待機に入ったとき・解けたときは 10 分を待たずに書き直す）。
アプリは「ステータス」タブの先頭に「上限で待機中」の節を出し、リポジトリごとに再開の時刻を表示する。

## ループの状態を書き出す（loop-status）

アプリの「ステータス」タブは、オーケストレーターが担当リポジトリごとに書き出す状態用の Issue を読む
（[Discussion #197](https://github.com/shilokuma-inc/ask-hub-apple/discussions/197)。形式は [`docs/protocol.md`](protocol.md) の「ループの状態」）。

- 毎回のポーリングの最後（利用上限で待機している間は、最終 PR の確認の後）に、`LoopStatusSummary` で担当リポジトリごとに、自動ループの状態を Discussion ごとにまとめる。
  材料は、ループのプロセスと state ファイル、制御用 worktree の epic（ブランチ・goal・`askhub-bootstrap.local.txt`）、利用上限の解除の時刻、
  異常終了・再開を諦めたか、起動を追っている Discussion（起動した・起動を諦めた。`LaunchTracker`）、回答が付いて再開を待っているか、まだ起動していない `ready-for-loop` の Discussion、
  最終 PR がマージ済みか（完了した epic だけ、10 分に 1 回まで問い合わせる）、最後に動いた時刻
  （`.claude/ralph-loop.local.md`・`ralph-state.local.md`・`ralph-goal.local.md`・最新のループのログの更新時刻のうち新しいもの）
- 状態用の Issue（ラベル `loop-status`、タイトル `【AskHub】ループの状態`）は、信用する author が作った open なもののうち最も新しく更新されたものを使う。
  無ければ閉じたものを開き直し、それも無ければ作る（ラベルが無ければ作る）。人が閉じても、次に書くときに開き直す
- 本文にはリポジトリ全体の状態（担当 PC の確認時刻・利用上限の解除の時刻）を、自動ループの状態はそのループ（Discussion）のコメントに書く
  （[Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425) の Q1。同じリポジトリで自動ループと手動ループが同時に回るため）。
  ゴール元の Discussion の番号が無い状態（手で始めた epic）はコメントに書かない
- 自動ループのコメントは Discussion ごとに 1 つ。同時に動く自動ループはリポジトリに 1 つのままだが、制御用 worktree に準備を終えた epic（例: 完了して最終 PR のマージ待ちの #12）が
  残ったまま別の Discussion（#30）を起動した・起動を諦めた・待っているときは、#12 のコメントに epic の状態を、#30 のコメントに起動の状態を書く（PR #437 の担当者の判断）。
  準備を終えた epic と別の Discussion を起動して開始を待っていれば、制御用 worktree のプロセス・state ファイルはそのループのものとし、epic を実行中にしない
- 自動ループのコメントを消すのは、その Discussion のループが終わったとき（最終 PR がマージされた・epic が退避されて起動の記録にも `ready-for-loop` にも無い）と、重複したとき、
  ほかの書き手（手動ループ・知らない書き手）がその Discussion を書いているとき（自分のコメントだけを消す）だけ。
  どの Discussion のものか分からないループがある間（手で始めた epic・起動の記録の無いループが動いている・起動してから `ready-for-loop` の一覧をまだ取得していない。
  上限で待機中に再起動したときなど）は、一覧に無い Discussion のコメントも消さない
- 本文もコメントも、状態が変わったときだけ書き換え、変わらなければ 10 分ごとに確認時刻だけを書き直す。
  オーケストレーターを再起動した直後は Issue の本文とコメントを読み、同じ状態なら書き直さない
- 書けなかったとき（コメントを読めなかったときも）はログに出し、次のポーリングで Issue とコメントの一覧から取り直して書き直す（読めないまま作らないので、コメントは重複しない）
- 書くのは epic 名・Discussion の番号・件数・時刻と、ビルドの情報の Mac の Host 名・スロットだけ。ローカルパス・ログの中身は書かない（public リポジトリでは誰でも読める）
- 設定の `buildHosts` があれば、ポーリングのたびに xcb のイベントログ（`events.jsonl`。回した `events.jsonl.1` も）を前回の続きから読み、
  ループのスロット（`<名前>-ralph-a` / `-b`）のビルドを `builds`（実行中・スロットごとの直近・24 時間の移動）に載せる（`docs/protocol.md` の「ビルドの情報」）。
  ほかのビルド（メインの checkout・制御用 worktree・手動ループのスロット `<名前>-ralph-d<番号>-a` / `-b`・手で流したビルド）は載せない。ビルドが 1 つも無ければキーを書かない。
  ビルドが変わったら（始まった・別の Mac に移った・終わった）状態の変化として書き換え、変わらなければ今までどおり 10 分ごとの確認時刻の書き直しに載せる。
  オーケストレーターを再起動したら、残っているイベントログを頭から読み直して組み立て直す（読んだ位置は保存しない）
- ビルドの情報は、準備を終えた epic の自動ループのコメントに書く。kit 1.3 までの手動ループが本文を書いていても、自動ループのコメントには書く
- `ready-for-loop` の検索に失敗したポーリングでは書き出さない（次のポーリングで書く）
- 手動ループ（ralph-kit 1.4.0 から）は、本文ではなく、そのループ（ゴール元の Discussion）のコメントに書き手 `manual` で書き、
  ゴール元の Discussion が閉じたら手動ループの側（`scripts/askhub-manual.sh` の見張り役）が消す。オーケストレーターは手動ループのコメントを書き換えず、消さない
- 書き換える前に Issue の一覧とコメントを取り直して読む（`LoopStatusPublisher`）。kit 1.3 までの手動ループ（目印の `writer` が `manual`）が
  古い形で本文を書いていて、`checkedAt` が 30 分以内なら本文は書かない（Discussion #273 の Q3）。手で回すループは 10 分ごとに `checkedAt` を書き直す。
  本文の Discussion が信用する author の open な `manual-loop` の Discussion のあいだ（本文に Discussion の番号が無ければ、そのリポジトリに信用する author の
  open な `manual-loop` の Discussion があるあいだ）は、手動ループの本文を（`checkedAt` が古くなっても）上書きしない（担当者の情報を残す。古さはアプリが知らせる）。
  Discussion が閉じた後に 30 分を過ぎていれば、本文をリポジトリ全体の状態で書き直す。どちらの間も、自動ループのコメントは書き続ける
- 手動ループのコメント（新しい形）・古い形の本文がある Discussion には、`checkedAt` が 30 分以内か、その Discussion が信用する author の open な `manual-loop` の
  Discussion のあいだ、自動ループのコメントを書かない（1 つの Discussion の書き手は 1 つ）。手動ループから自動ループに切り替えた Discussion は、
  同じリポジトリでほかの Discussion を手で回していても、残った古い手動ループのコメントでは止めない。`manual-loop` の Discussion を検索できなかったポーリングでは、
  前回取得できた番号を使う。知らない書き手のコメントがある Discussion にも書かない。
  `manual-loop` の Discussion と信用しない author の Discussion は起動しないので、`ready-for-loop` が付いていても開始待ちとして書かない
- 起動した Discussion は、準備が終わる前（ゴール元の記録も promise も無い）も、起動の記録（`LaunchTracker`）から実行中として書く。起動を諦めたら異常終了として書く。
  開始を確かめた後にラベルを外せないまま残った Discussion は、制御用 worktree が別の epic に替わったら（別の Discussion の epic を準備した・別の Discussion を起動した）、終わったループとして書かない。
  準備を終えていない `ready-for-loop` の Discussion は、すべて開始待ちとして書く（準備の結果やることが無かった Discussion は除く）

## ビルドの Mac の状態を書き出す（build-hosts）

設定の `buildHosts.issueRepository` が担当リポジトリにあれば、ループの状態を書き出した後に、xcb のビルド先の Mac の状態を
そのリポジトリの Issue（ラベル `build-hosts`、タイトル `【AskHub】ビルドの Mac の状態`。`docs/protocol.md` の「ビルドの Mac の状態」）に書き出す。

- Mac の状態（使える・切断・外している・待機）・使えない理由の分類・実行中の本数・ループのスロットの実行中のビルドは、xcb のイベントログから組み立てる。
  変わったら（Mac が切断された・戻った・`xcb drain` された・ビルドが始まった・移った・終わった）、間隔を待たずに書き換える
- コア数・load・空きメモリ・同時に実行できる本数は、10 分ごとの確認時刻の書き直しのときだけ `xcb status --json` を呼んで載せる（各 Mac に ssh で問い合わせるため、毎回は呼ばない）。
  load・空きメモリの揺れは変化として扱わない。`xcb status --json` が失敗したら、ログに出して前の値のまま書く
- Mac の並びは `xcb status --json` の順。状態は変わるたびに記録されるイベントのほうを使う（`xcb status --json` の値は最大 10 分古い）
- xcb の理由の文（`host_state` の `reason`）はローカルパスを含むことがあるので、分類（接続できない・実行中に切断・Xcode が未準備）だけを書く
- Issue は信用する author が作った open なもののうち最も新しく更新されたものを使い、無ければ閉じたものを開き直し、それも無ければ作る（ラベルが無ければ作る）
- オーケストレーターを再起動した直後は Issue の本文を読み、同じ状態なら書き直さない

## GitHub の情報から最終 PR を作る

制御用 worktree の「最終 PR に載せる内容」が使えない epic は、次の場合に GitHub の情報から最終 PR を作る（ポーリングの最後）。
同じリポジトリで複数のループ（自動ループと手動ループ・複数の手動ループ）が回るので、候補はループ（epic）ごとに出し、両方の経路を並べて見る
（[Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425)）。GitHub への問い合わせ（既にある PR・材料）は epic ごとに 10 分に 1 回まで。

- **手動ループ**（`manual-loop` の Discussion が open なリポジトリ）: 信用する author が作った状態用の Issue の本文と、信用する author のループごとのコメント（`LoopStatusBoard`）のうち、
  書き手が `manual`・状態が `completed` で、epic が書かれていて、書かれてから 30 分（`LoopStatusReport.freshness`）たった、open な `manual-loop` の Discussion のループ
  （`manual-loop` の Discussion を取得できなかったポーリングでは絞らない）。
  担当者が `scripts/askhub-manual.sh final`（手元の state の内容で作る）を流すのを、その間は待つ。状態用の Issue の読み直しはリポジトリごとに 10 分に 1 回まで
- **自動ループ**: ループが正常に止まり（異常終了したものは再開して内容を書かせるので除く）、タスクもすべて終わっているのに「最終 PR に載せる内容」が空。
  手動ループがあっても見る。ただし手動ループのあるリポジトリでは、制御用 worktree の epic のゴール元が `manual-loop` の Discussion のとき・記録が無いときは、
  この PC の手動ループのものとして自動ループの経路では作らない（回答による再開と同じ判定）

材料は、epic にマージされた子 PR・epic 宛てでまだ open の子 PR・タイトルか本文で epic に触れている open な仮決め一覧（`decision-log`）と実機確認（`needs-verify`）の Issue。
本文の先頭にゴール元の Discussion の目印を置き、`epic-final` を付ける。GitHub の情報から作ったことも書き添える。
同じ epic では 1 回だけ作る（閉じた PR を含め、既存の PR があれば作らない）。マージされた子 PR が 1 つも無い epic は作らない。

## epic の最終 PR のコンフリクトを解消する

epic の最終 PR が既定ブランチとコンフリクトすると、AskHub のアプリからはマージも解消もできない。ポーリングの最後に探し、見つけたら次を**裏で**行う
（[Discussion #425](https://github.com/shilokuma-inc/ask-hub-apple/discussions/425) の Q3）。解消は最長 30 分かかるが、ポーリングはその終わりを待たずに続ける。

- 同じリポジトリでは 1 件ずつ、別のリポジトリは並列に解消する（`askhub-resolve-conflict` はメインの checkout に一時 worktree を作るため、同じリポジトリでは並べない）
- 同じリポジトリでほかの最終 PR（自動ループと手動ループの epic など）もコンフリクトしていれば、前の解消が終わったところで、次のポーリングを待たずに始める。
  今終わった PR は push で head が変わっているので、まだコンフリクトしていれば次のポーリングで取得し直してから試す

1. org 全体の open な `epic-final` PR のうち、GitHub が `CONFLICTING` と判定したものを探す（`UNKNOWN` はまだ判定中なので次のポーリングに回す）。担当リポジトリのものだけを扱う
2. `conflictCommand`（既定は `askhub-resolve-conflict`）を実行し、終わるまで裏で待つ。スクリプトはループの作業場所（制御用 worktree・スロット）とは別の一時 worktree で、head に base を取り込む
   - コンフリクトしなければ、そのまま head に push する（`ASKHUB_RESULT: merged`）
   - コンフリクトしたら `claude -p` に解消させ、CLAUDE.md の検証コマンドを通させてからマージコミットを作らせる。
     スクリプトが、マージが完了していること・コンフリクトの印が残っていないこと・head と base の両方を含むことを確かめてから、
     `--force-with-lease` で push する（`ASKHUB_RESULT: resolved`）。確かめられなければ push しない（`ASKHUB_RESULT: unresolved <理由>`）
3. 結果を PR にコメントする。解消できなかったときは理由と、手元での解消が要ることを書く。
   コメントの先頭に `<!-- ask-hub:orchestrator -->` を置き、最終 PR への指示と見分けさせる（`docs/protocol.md` の「最終 PR への指示」）
4. 同じ組み合わせ（head と base のコミット）では 1 回しか試さない。解消できなかったのが 3 回続いたら、その PR はあきらめる。
   コンフリクトが無くなった（検索に出なくなった）PR は忘れる。記録はメモリ上だけなので、再起動すると数え直す
5. Claude の利用上限で終わったときは試したことにせず、解除の後に試し直す。上限で待機しているあいだは、新しい解消を始めない（実行中の解消は終わるまで待つ）

`--once` で 1 回だけポーリングしたときと、ポーリングを終えるとき（`run` が戻るとき）は、実行中の解消が終わって結果を PR にコメントするまで待ってから終わる
（解消の子プロセスはオーケストレーターが終わっても止まらないため）。待っている間は、同じリポジトリの次の最終 PR を始めない。launchd の停止・再起動ではプロセスがすぐに終わるので待たない（`AbandonProcessGroup` で子プロセスは残る）。
記録はメモリ上だけなので、再起動した後に、まだコンフリクトしている PR を試し直すことがある（今までと同じ）

ログは `~/Library/Logs/askhub/loops/<リポジトリ>-conflict-<PR 番号>-*.log`（claude の出力）。

## epic の最終 PR を第三者レビューする

最終 PR（`epic-final`）で CodeRabbit がレビューできないときは、ポーリングの最後（コンフリクトの解消の後）に、
`reviewCommand`（既定は `askhub-review-final`）で第三者レビューを、要修正があれば `fixCommand`（既定は `askhub-fix-review`）で修正を**裏で**行う
（[Discussion #503](https://github.com/shilokuma-inc/ask-hub-apple/discussions/503)。進み具合の追跡は `FinalReviewTracker`）。
アプリはマージ待ちと同じ取得（`GitHubMergeQueue`）で、信用する author が作った PR の CodeRabbit の状態と、信用する author が書いた今の head の第三者レビューを読む。

- 今の head を見始めてから 10 分経っても CodeRabbit のレビューが完了しないか、CodeRabbit がレート制限・失敗・スキップなら第三者レビューを始める。
  コンフリクトしている（GitHub がまだ判定していないものも）PR は始めない。CodeRabbit が今の head をレビューしたら、レビュー・修正はやめる
- 要修正があれば次のポーリングで直させ、push で head が変わったら新しい head をまたレビューする。要修正が 3 回続いたら、あきらめて PR にコメントする
  （人が直して push すれば、また 10 分待ちから回る。自分の修正の push 以外で head が変わったら回数を 0 に戻す）。コマンドが同じ head で 3 回続けて失敗したときもあきらめる
- コンフリクトの解消と合わせて、同じリポジトリでは 1 件ずつ（どちらもメインの checkout に一時 worktree を作るため）。別のリポジトリは並列に行う
- コマンドには、ループと同じく信用する author（`ASKHUB_TRUSTED_AUTHORS`）と設定の `model` / `effort` を渡す。制限時間はレビュー 30 分・修正 60 分
- Claude の利用上限で終わったときは試したことにせず、解除の後に試し直す。上限で待機しているあいだは始めない
- `--once` とポーリングを終えるときは、コンフリクトの解消と同じく、実行中のレビュー・修正が終わるまで待つ。記録はメモリ上だけなので、再起動すると数え直す
- 待ち始めた時刻もメモリ上だけなので、起動・再起動の後に初めて見た最終 PR では、今の head を GitHub が受け取った時刻の推定から 10 分を数える
  （commit status `CodeRabbit` の時刻。無ければ head のコミットの日時。PR の作成時刻より前なら作成時刻、未来の時刻なら見た時刻）。再起動のたびに 10 分待ち直さない。
  追跡中に head が変わったのを見たときは、見た時刻から数える
- 進み具合は、最終 PR に目印（`ask-hub:final-review`）付きの状態コメント 1 件として書き出し、変わったら書き換える（`docs/protocol.md` の「最終 PR の第三者レビューの進み具合」）。
  CodeRabbit を待っている間と CodeRabbit がレビューしたときは、まだコメントが無ければ作らない。書き出しに失敗したら次のポーリングで書き直す

ログは `~/Library/Logs/askhub/loops/<リポジトリ>-review-<PR 番号>-*.log` と `…-fix-review-<PR 番号>-*.log`（claude の出力）。

### 状態と遷移

`FinalReviewTracker` が最終 PR ごとに持つ状態。状態コメントの目印の `state` と同じ（`docs/protocol.md` の「最終 PR の第三者レビューの進み具合」）。

| 状態 | 意味 | 次に行うこと |
| --- | --- | --- |
| `waiting` | head を見始めた（CodeRabbit を待っている） | 10 分経つか、CodeRabbit がレート制限・失敗・スキップなら第三者レビュー → `reviewing` |
| `reviewing` | `reviewCommand` を実行中 | 要修正 0 件 → `done`、要修正あり → `fixing`（3 回目なら `gave-up`）、head が進んでいた → `waiting`（新しい head が見えるまで待つ）、失敗 → `waiting`（3 回続いたら `gave-up`） |
| `fixing` | 要修正を直す（`fixCommand`）。push した後は新しい head が見えるまで待つ | push で head が変わる → 新しい head で `waiting`（回数は引き継ぐ）、head が進んでいた → `waiting`（新しい head が見えるまで待つ）、失敗 → 直し直す（3 回続いたら `gave-up`） |
| `done` | 今の head の第三者レビューで要修正が 0 件 | 何もしない（アプリからマージできる） |
| `done-coderabbit` | CodeRabbit が今の head をレビューした（どの状態からでもなる。Q2） | 何もしない（アプリからマージできる） |
| `gave-up` | 要修正が 3 回続いた・コマンドが同じ head で 3 回続けて失敗した | PR にあきらめたことをコメントする。アプリからはマージできない（GitHub の画面からはできる） |

- head が変わったら、どの状態からでも `waiting` に戻り、待ち始めから数え直す（Q3）。要修正が続いた回数は、自分の修正の push で変わったときだけ引き継ぎ、
  人の push・コンフリクトの解消・develop の取り込みなら 0 に戻す（人が直して push すればまた回る。Q1）
- 一覧から消えた（マージ・クローズされた）PR は追跡をやめる
- Claude の利用上限などで結果を記録せずに終えたときは、`reviewing` は `waiting` に戻り、`fixing` はそのまま（解除の後に試し直す）

### `askhub-review-final`（第三者レビュー）

`scripts/orchestrator/review-final.sh`。引数は `reviewCommand` の既定と同じ `<owner/repo> <checkoutPath> <headBranch> <baseBranch> <pullRequest> <headSHA>`。

1. origin の head が `headSHA` のままかを確かめ、進んでいれば何もしない（`ASKHUB_RESULT: stale`）
2. 一時 worktree に `headSHA` を checkout し、差分（`origin/<base>...<headSHA>`）と前回の第三者レビュー（`ASKHUB_TRUSTED_AUTHORS` の author が書いた目印付きのコメントのうち最新）を worktree の外に置く
3. 実装の文脈を持たない `claude -p` にレビューさせる。プロンプトは標準入力で渡し、`--restricted --strict-mcp-config --tools "Read,Grep,Glob" --add-dir <一時ディレクトリ>` で
   読むツールだけ・一時ディレクトリの中だけに限る（差分の文によるプロンプトインジェクションへの備え）。本文は `ASKHUB_REVIEW_BEGIN` 〜 `ASKHUB_REVIEW_END` の間に返させる
4. 件数は claude の申告ではなく、本文の表の行（`🔴 要修正` / `🟡 提案`。対応が「修正済み」の行は数えない）から数える。重要度を読み取れない行・トークンらしい文字列があれば投稿しない。
   HTML コメントは文字参照に書き換える
5. コメントの直前に head をもう一度確かめ、目印（`ralph:third-party-review sha must may`）と見出しを付けて PR にコメントする（`ASKHUB_RESULT: reviewed must=N may=M`）

### `askhub-fix-review`（要修正の修正）

`scripts/orchestrator/fix-review.sh`。引数は `askhub-review-final` と同じ。

1. origin の head が `headSHA` のままかを確かめ、`headSHA` の第三者レビュー（信用する author のもの・最新）を読む。レビューが無い・要修正が 0 件なら失敗（`failed`）にする（オーケストレーターは失敗に数える）
2. 一時 worktree で `claude -p` に `🔴 要修正` だけを直させ、CLAUDE.md の検証を通させてコミットさせる（push・rebase・amend はさせない）
3. push の前に確かめる: コミットしていない変更が無い・コミットが増えた・`headSHA` の上に積んだ・マージコミットが無い・差分がある・AI の帰属行が無い
4. origin の head が `headSHA` のままなら `--force-with-lease=refs/heads/<epic>:<headSHA>` で push する（`ASKHUB_RESULT: fixed <新しい head>`）。
   進んでいれば push しない（`stale`）。claude が自分で push していたら失敗にする

どちらも、失敗は `ASKHUB_RESULT: failed <理由>`（終了コード 2）。origin を読めなかったときも `stale` ではなく失敗にする。

## 固まったループを止める

`claude -p` が API の応答待ちなどで止まり、プロセスは生きたまま周回が進まなくなることがある。プロセスが生きていれば「動いている」とみなすだけでは気付けないので、毎回のポーリングの最初に次を確かめる。

1. ralph-loop の Stop hook は周回ごとに state ファイル（`.claude/ralph-loop.local.md`）を書き直すので、その更新時刻を今の周回の開始時刻とみなす
2. `.claude/askhub-loop.pid` のプロセスが生きていて、state ファイルが `iterationTimeoutMinutes`（既定 90 分）より長く書き直されていなければ、固まったとみなして SIGTERM を送り、10 秒たっても残っていれば SIGKILL で止める
   - PID が別のプロセスに再利用されていないことを、プロセスの起動時刻が PID ファイルの更新時刻より前であることで確かめる（起動スクリプトは PID を書いてから `claude` に exec する）
3. 止めたループは state ファイルが残ったままプロセスが居なくなるので、「異常終了したループを再開する」の手順で再開する（同じポーリングで再開する）

ビルドとテストが重く、1 周が 90 分を超えるリポジトリがあれば `iterationTimeoutMinutes` を延ばす。

## Claude の利用上限で止まったら、解除の時刻に再開する

この Mac の Claude アカウントが利用上限に達すると、`claude` は次のような行を出して終わる。

- `You've hit your session limit · resets 12pm (Asia/Tokyo)`
- `You've hit your weekly limit · resets Oct 7, 9am (Asia/Tokyo)`
- `Claude AI usage limit reached|<解除の UNIX 時刻>`

1. 起動スクリプトは、担当リポジトリの最新のログ（準備・ループ）を `<ログの置き場所>/<リポジトリ名>-latest.log` のリンクで指す
2. オーケストレーターは毎回のポーリングで、止まっているループの最新のログの末尾（最後の 5 行）から上限のメッセージを探し、解除の時刻を読む（`UsageLimit`、副作用なし）。
   時刻だけの `resets 12pm` はログの更新時刻より後の最初のその時刻、読めなければ 1 時間後とみなす。`ideaCommand` の出力も同じく見る
3. 解除の時刻まで、この Mac のループの起動・再開と、依頼からの Discussion の作成を止める（アカウントは Mac ごとに共通なので、リポジトリを問わず止める）。
   最終 PR の作成は `claude` を使わないので続ける
4. 上限で止まった分は、異常終了の再開（`StallWatcher`）と `ready-for-loop` の起動（`LaunchTracker`）の失敗に数えない。諦めた Discussion も起動し直す
5. 解除の時刻を過ぎたら、いつもの判定に戻り、止まっていたループを再開する

