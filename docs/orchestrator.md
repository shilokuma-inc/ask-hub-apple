# オーケストレーター（askhub-orchestrator）

AskHub の回答を受けて、ループ（ralph-loop）を自動で起動・再開する macOS の CLI。
`AskHubKit/Package.swift` の executable ターゲット `askhub-orchestrator` としてビルドする。
アプリは GitHub だけを見るクライアントで、`claude` / `git` / `xcodebuild` の起動はすべてオーケストレーターが行う
（Discussion #1 の Q2）。

> 現時点では設定ファイルを読み込んで内容を表示するところまで。ポーリングと各アクションは後続の PR で追加する。

## ビルドと実行

```bash
swift build --package-path AskHubKit -c release --product askhub-orchestrator
"$(swift build --package-path AskHubKit -c release --show-bin-path)/askhub-orchestrator" --config ~/.config/askhub/orchestrator.json
```

| オプション | 説明 |
| --- | --- |
| `--config <path>` | 設定ファイルの場所。既定は `~/.config/askhub/orchestrator.json` |
| `-h`, `--help` | 使い方を表示する |

終了コードは、引数の誤りが `64`（`EX_USAGE`）、設定ファイルの誤りが `78`（`EX_CONFIG`）。

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
