# オーケストレーター（askhub-orchestrator）

AskHub の回答を受けて、ループ（ralph-loop）を自動で起動・再開する macOS の CLI。
`AskHubKit/Package.swift` の executable ターゲット `askhub-orchestrator` としてビルドする。
アプリは GitHub だけを見るクライアントで、`claude` / `git` / `xcodebuild` の起動はすべてオーケストレーターが行う
（Discussion #1 の Q2）。

> 現時点で行うのは「`ready-for-loop` の Discussion を検知してループを起動する」だけ。
> ask の回答による再開や、最終 PR の作成などは後続の PR で追加する。

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

### `loopCommand` のプレースホルダ

各引数の中の次の文字列を、起動するリポジトリの値に置き換える。未知の `{name}` があると設定エラーになる。

| プレースホルダ | 値 |
| --- | --- |
| `{repository}` | `owner/repo` |
| `{checkoutPath}` | メインの checkout のパス |
| `{controlPath}` | 制御用 worktree のパス。`scripts/ralph-setup.sh` と同じく checkout の隣の `<ディレクトリ名から -ios を除いたもの>-ralph-ctl` |
| `{discussion}` | ループのゴール元の Discussion の番号（`ready-for-loop` から起動するとき）。Discussion を伴わない起動では空文字列 |
