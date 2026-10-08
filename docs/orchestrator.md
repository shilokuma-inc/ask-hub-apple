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
   あわせて `manual-loop` が付いた open な Discussion も 1 回の検索で取る（失敗したらログに出し、そのポーリングでは起動しない。依頼・最終 PR のコンフリクト・ループの状態の書き出しは続ける）
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
   | `manual-loop` が付いている（手で回す Discussion） | 起動しない（ログに出す）。`ready-for-loop` も外さない（手で回すループが始めるときに外す） |
   | 同じリポジトリに、信用する author の open な `manual-loop` の Discussion がある（手で回す epic が終わっていない） | 起動しない（ログに出す。Discussion #273 の Q4: 1 リポジトリにつきループは 1 つ）。手で回す epic は見えないので、Discussion が閉じられる（最終 PR のマージ）まで待つ。質問が残っている `manual-loop` の Discussion も含む |
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

以前の設定にあった `org` は不要になった（書いてあっても無視する）。

設定ファイルは**ポーリングのたびに読み直す**。担当リポジトリの追加・削除などは、オーケストレーターを再起動しなくても次のポーリングから効く。
読めないとき（書きかけ・JSON の誤り）はログに 1 回だけ理由を出し、直るまで前の設定のまま動く。
信用する author（設定の `trustedAuthors` と、担当リポジトリへの書き込み権限を持つアカウント）は、ポーリングのはじめに担当リポジトリごとに求め直し（書き込み権限は 10 分ごとに取り直す）、
変わったらログに `<リポジトリ> で信用する author: …` と出す。ループには起動ごとに `ASKHUB_TRUSTED_AUTHORS` で渡す。
アプリからの担当リポジトリの作成・削除の依頼では、オーケストレーターが `repositories` を書き換える（下記）。

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
| `discussion` が空（ask への回答・仮決め一覧への指示・異常終了で再開） | 既存の制御用 worktree でループを起動し直す。片付け済みのスロットは作り直す。未完了のタスクが無ければ何もしない。ただし環境変数 `ASKHUB_RESUME_REASON=decision-log`（仮決め一覧への指示による再開）のときは、タスクが無くても起動する（指示はループが周回の最初に読んで修正タスクにするため） |
| state ファイルがある | ループが動いているので何もしない。ただし記録した PID（`.claude/askhub-loop.pid`）のプロセスが終わっていれば、残った state を片付けて続ける |

- 前の epic が完了済み（未完了のタスクが無い）なら、制御用 worktree の `.claude/` を `~/Library/Logs/askhub/archive/` に退避してから worktree を片付ける。
  未完了なら新しい epic は始めない（1 リポジトリにつきループは 1 つ）。
  worktree にコミットしていない変更がある・退避に失敗したときは、片付けずに失敗として返す
- 信用する author は、オーケストレーターが起動ごとに環境変数 `ASKHUB_TRUSTED_AUTHORS` で渡す（設定の `trustedAuthors` と、そのリポジトリへの書き込み権限を持つアカウント。手で設定する必要は無い）。
  再開では、制御用 worktree の playbook の「信用する author」もこの値に書き直す
- 再開の理由は、オーケストレーターが起動ごとに環境変数 `ASKHUB_RESUME_REASON` で渡す（今は仮決め一覧への指示による再開の `decision-log` だけ。`loopCommand` に書く必要は無い）
- オーケストレーターも PID ファイルを読み、state ファイルが残っていても PID のプロセスが居なければ「止まっている」とみなして再開する
- 準備が途中で失敗した場合（完了語を読み取れない等）は、オーケストレーターの再試行で、同じ Discussion の途中の worktree を片付けてやり直す
- ループは `claude -p --permission-mode bypassPermissions` を `exec` で起動する。このプロセスの寿命がループの寿命になる。
  ralph の Stop hook はヘッドレスでも周回する（標準入力は `/dev/null`）
- ログは `~/Library/Logs/askhub/loops/<リポジトリ>-bootstrap-*.log`（準備）と `<リポジトリ>-loop-*.log`（ループ）
- 環境変数で `claude` の場所・ログの場所・信用する author・準備のモデルを変えられる（スクリプト冒頭のコメントを参照）
- **xcodebuild のラッパー**: 環境変数 `ASKHUB_XCODEBUILD_WRAPPER`、または `~/.config/askhub/xcodebuild`（実行可能なとき）に
  ラッパーを置くと、新しい epic の準備で playbook の検証コマンドを `<ラッパー> "$PWD" <xcodebuild の引数…>` の形で書かせ、
  「このアプリ固有の前提」にも同じ規則を入れさせる。ラッパーは第 1 引数に作業ツリーのパスを取り、残りを xcodebuild にそのまま渡し、
  終了コードを返すこと。Simulator（`name=` 指定）と DerivedData の作業ツリーごとの分離もラッパーが受け持つ
  （例: ビルド専用機へ ssh で回す・同時実行数を絞る）。置かなければ従来どおり、UDID の `id=` とスロットごとの `-derivedDataPath` で書かせる。
  既存の epic の playbook は作り直さないので、変えるときは手で書き換える

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

1. 担当リポジトリの owner の organization 全体から `needs-answer` の open な Discussion / PR を取得し（`GitHubInboxSource`）、担当リポジトリのものだけを扱う
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
   ただし、信用する author の Discussion に `manual-loop` が付いていれば（手で回す Discussion）、`ready-for-loop` は付けずに
   `needs-answer` だけを外す（ログに「manual-loop（手で回す）なので、ready-for-loop は付けません」と出す）。
   `manual-loop` と author は `needs-answer` の検索結果から読む。信用外の author の Discussion に付いた `manual-loop` は無視し、今までどおり扱う

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

1. ループのプロセスが動いていれば外さない。制御用 worktree に state ファイルが残っていれば、強制の依頼でなければ外さない
2. ローカルも消す依頼なら、`removeRepositoryCommand`（既定は `scripts/orchestrator/remove-repo.sh`）に
   `[--force] <checkout のパス> <制御用 worktree のパス>` を足して実行する。スクリプトは、強制でなければ
   未コミットの変更（ループの作業ファイル `.claude/askhub-*`・`.claude/ralph-*.local.*` は除く）・stash・どのリモートにも無いコミットを持つブランチがないかを確かめる。
   ブランチは、既定ブランチに取り込んでも木が変わらなければ（squash merge 済みなど）消してよいものとして扱う。
   消してよければ、制御用 worktree の `.claude/` を `~/Library/Logs/askhub/archive/<名前>/removed-<日時>/` に退避してから、
   checkout・ループの worktree・checkout の隣の DerivedData（`<名前>-ralph-dd*` など）・Xcode の既定の DerivedData のうちそのプロジェクトのものを消す
3. 設定ファイルの `repositories` から外し、担当の印（`askhub-orchestrator` のラベル）を消す（アプリで「担当 PC なし」になる）

スクリプトは人に伝える行を `ASKHUB_RESULT: …`、失敗の理由を `ASKHUB_ERROR: …` で出す。依頼 Issue にはこの行だけを書き、ほかの出力はログにだけ残す。
前提を満たさない（既に同名のリポジトリがある・未 push の変更がある など）ときは終了コード 3 で終わり、やり直さずに理由をコメントする。
それ以外の失敗は 1 回だけやり直し、それでも失敗したら理由をコメントする。

## 担当の印（askhub-orchestrator）

アプリは担当 PC を知らないので、オーケストレーターは毎回のポーリングの最初に、担当リポジトリのラベル `askhub-orchestrator` の説明へ
最終確認の時刻を書く（同じリポジトリには 10 分に 1 回まで。ラベルが無ければ作る）。
アプリの「ループ」タブの「ループの開始待ち」は、この時刻が 30 分より古い・無いリポジトリの `ready-for-loop` を「担当 PC なし」と出す。
書けなかったときはログに出し、次のポーリングで書き直す。
利用上限で待機している間は、説明の末尾に `・上限で待機中: <解除の時刻>` を足す（待機に入ったとき・解けたときは 10 分を待たずに書き直す）。
アプリは「ループ」タブの先頭に「上限で待機中」の節を出し、リポジトリごとに再開の時刻を表示する。

## ループの状態を書き出す（loop-status）

アプリの「ループ」タブは、オーケストレーターが担当リポジトリごとに書き出す状態用の Issue を読む
（[Discussion #197](https://github.com/shilokuma-inc/ask-hub-apple/discussions/197)。形式は [`docs/protocol.md`](protocol.md) の「ループの状態」）。

- 毎回のポーリングの最後（利用上限で待機している間は、最終 PR の確認の後）に、`LoopStatusSummary` で担当リポジトリごとの状態をまとめる。
  材料は、ループのプロセスと state ファイル、制御用 worktree の epic（ブランチ・goal・`askhub-bootstrap.local.txt`）、利用上限の解除の時刻、
  異常終了・起動・再開を諦めたか、回答が付いて再開を待っているか、まだ起動していない `ready-for-loop` の Discussion、
  最終 PR がマージ済みか（完了した epic だけ、10 分に 1 回まで問い合わせる）、最後に動いた時刻
  （`.claude/ralph-loop.local.md`・`ralph-state.local.md`・`ralph-goal.local.md`・最新のループのログの更新時刻のうち新しいもの）
- 状態用の Issue（ラベル `loop-status`、タイトル `【AskHub】ループの状態`）は、信用する author が作った open なもののうち最も新しく更新されたものを使う。
  無ければ閉じたものを開き直し、それも無ければ作る（ラベルが無ければ作る）。人が閉じても、次に書くときに開き直す
- 本文は状態が変わったときだけ書き換え、変わらなければ 10 分ごとに確認時刻だけを書き直す。
  オーケストレーターを再起動した直後は Issue の本文を読み、同じ状態なら書き直さない
- 書けなかったときはログに出し、次のポーリングで Issue の一覧から取り直して書き直す
- 本文に書くのは epic 名・Discussion の番号・件数・時刻だけ。ローカルパス・ログの中身・PC 名は書かない（public リポジトリでは誰でも読める）
- `ready-for-loop` の検索に失敗したポーリングでは書き出さない（次のポーリングで書く）
- 本文を書き換える前に Issue の一覧を取り直して本文を読む。手で回しているループ（目印の `writer` が `manual`）が書いていて、
  `checkedAt` が 30 分以内なら書かない（`LoopStatusPublisher`。Discussion #273 の Q3）。手で回すループは 10 分ごとに `checkedAt` を書き直す。
  手で回すループが止まって 30 分を過ぎたら、オーケストレーターが自分の材料で今までどおりの優先順位で書き直す
  （オーケストレーターからは手で回す制御用 worktree が見えないので、多くは「ループなし」か `ready-for-loop` の「開始待ち」になる）

## epic の最終 PR のコンフリクトを解消する

epic の最終 PR が既定ブランチとコンフリクトすると、AskHub のアプリからはマージも解消もできない。ポーリングの最後に（1 回のポーリングで 1 件）、次を行う。

1. org 全体の open な `epic-final` PR のうち、GitHub が `CONFLICTING` と判定したものを探す（`UNKNOWN` はまだ判定中なので次のポーリングに回す）。担当リポジトリのものだけを扱う
2. `conflictCommand`（既定は `askhub-resolve-conflict`）を、終わるまで待って実行する。スクリプトはループの作業場所（制御用 worktree・スロット）とは別の一時 worktree で、head に base を取り込む
   - コンフリクトしなければ、そのまま head に push する（`ASKHUB_RESULT: merged`）
   - コンフリクトしたら `claude -p` に解消させ、CLAUDE.md の検証コマンドを通させてからマージコミットを作らせる。
     スクリプトが、マージが完了していること・コンフリクトの印が残っていないこと・head と base の両方を含むことを確かめてから、
     `--force-with-lease` で push する（`ASKHUB_RESULT: resolved`）。確かめられなければ push しない（`ASKHUB_RESULT: unresolved <理由>`）
3. 結果を PR にコメントする。解消できなかったときは理由と、手元での解消が要ることを書く
4. 同じ組み合わせ（head と base のコミット）では 1 回しか試さない。解消できなかったのが 3 回続いたら、その PR はあきらめる。
   コンフリクトが無くなった（検索に出なくなった）PR は忘れる。記録はメモリ上だけなので、再起動すると数え直す
5. Claude の利用上限で終わったときは試したことにせず、解除の後に試し直す

ログは `~/Library/Logs/askhub/loops/<リポジトリ>-conflict-<PR 番号>-*.log`（claude の出力）。

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

