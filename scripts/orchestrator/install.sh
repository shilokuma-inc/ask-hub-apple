#!/bin/bash
# askhub-orchestrator を release ビルドして配置し、launchd の LaunchAgent の plist を書き出す。
#   usage: scripts/orchestrator/install.sh [--prefix <dir>] [--config <path>] [--agents-dir <dir>] [--log-dir <dir>]
# launchd への登録（launchctl）は行わない。最後に登録のコマンドを表示するので、内容を確かめてから実行する。
set -euo pipefail

LABEL="jp.shilokuma.askhub-orchestrator"
PREFIX="$HOME/.local/bin"
CONFIG="$HOME/.config/askhub/orchestrator.json"
AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="$HOME/Library/Logs/askhub"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prefix) PREFIX="${2:?--prefix には値が必要です}"; shift 2 ;;
    --config) CONFIG="${2:?--config には値が必要です}"; shift 2 ;;
    --agents-dir) AGENTS_DIR="${2:?--agents-dir には値が必要です}"; shift 2 ;;
    --log-dir) LOG_DIR="${2:?--log-dir には値が必要です}"; shift 2 ;;
    -h|--help) sed -n '2,4p' "$0" | sed 's/^# //'; exit 0 ;;
    *) echo "未知のオプションです: $1" >&2; exit 64 ;;
  esac
done

# 引用符で渡された `~` を展開し、相対パスは実行した場所を基準に絶対パスにする。
# plist の WorkingDirectory は $HOME なので、相対パスのままだと別の場所を指してしまう
absolute_path() {
  local path="$1"
  # 展開されずに届いた文字の `~` を照合するので、引用符で囲んだままにする
  # shellcheck disable=SC2088
  case "$path" in
    "~") path="$HOME" ;;
    "~/"*) path="$HOME/${path#"~/"}" ;;
  esac
  case "$path" in
    /*) printf '%s' "$path" ;;
    *) printf '%s/%s' "$PWD" "$path" ;;
  esac
}
PREFIX=$(absolute_path "$PREFIX")
CONFIG=$(absolute_path "$CONFIG")
AGENTS_DIR=$(absolute_path "$AGENTS_DIR")
LOG_DIR=$(absolute_path "$LOG_DIR")

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
TEMPLATE="$REPO_ROOT/scripts/orchestrator/$LABEL.plist.template"

# gh / claude / git の場所を PATH に入れる。見つからないものは警告だけ出す（設定ファイルで絶対パスを使う場合もある）
SEARCH_PATH="$PREFIX:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
for command in gh claude git; do
  if ! PATH="$SEARCH_PATH" command -v "$command" >/dev/null 2>&1; then
    echo "警告: $command が $SEARCH_PATH に見つかりません。launchd から起動したときに使えない可能性があります" >&2
  fi
done
if [[ ! -f "$CONFIG" ]]; then
  echo "警告: 設定ファイルがありません: ${CONFIG}（docs/orchestrator.md の「設定ファイル」を参照）" >&2
fi

echo "release ビルド中…"
swift build --package-path "$REPO_ROOT/AskHubKit" -c release --product askhub-orchestrator >/dev/null
BIN_DIR=$(swift build --package-path "$REPO_ROOT/AskHubKit" -c release --show-bin-path)

mkdir -p "$PREFIX" "$AGENTS_DIR" "$LOG_DIR"
install -m 755 "$BIN_DIR/askhub-orchestrator" "$PREFIX/askhub-orchestrator"
# loopCommand から呼ぶループの起動スクリプト。checkout の場所に依存しないよう、実行ファイルと同じ場所に置く
install -m 755 "$REPO_ROOT/scripts/orchestrator/start-loop.sh" "$PREFIX/askhub-start-loop"
# conflictCommand の既定（epic の最終 PR のコンフリクトを解消する）。loopCommand と同じ場所に置く
install -m 755 "$REPO_ROOT/scripts/orchestrator/resolve-conflict.sh" "$PREFIX/askhub-resolve-conflict"

# XML に入る値なので、& < > をエスケープしてから置き換える
escape() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
replace() { printf '%s' "$1" | sed -e 's/[\\/&|]/\\&/g'; }
PLIST="$AGENTS_DIR/$LABEL.plist"
sed \
  -e "s|@LABEL@|$(replace "$LABEL")|g" \
  -e "s|@BINARY@|$(replace "$(escape "$PREFIX/askhub-orchestrator")")|g" \
  -e "s|@CONFIG@|$(replace "$(escape "$CONFIG")")|g" \
  -e "s|@PATH@|$(replace "$(escape "$SEARCH_PATH")")|g" \
  -e "s|@HOME@|$(replace "$(escape "$HOME")")|g" \
  -e "s|@LOG_DIR@|$(replace "$(escape "$LOG_DIR")")|g" \
  "$TEMPLATE" > "$PLIST"
plutil -lint "$PLIST" >/dev/null

cat <<MSG

インストールしました
  実行ファイル: $PREFIX/askhub-orchestrator
  起動スクリプト: $PREFIX/askhub-start-loop（設定の loopCommand に指定する）
  コンフリクトの解消: $PREFIX/askhub-resolve-conflict（conflictCommand の既定）
  plist:        $PLIST
  ログ:         $LOG_DIR/orchestrator.log

設定を確かめてから（"${PREFIX}/askhub-orchestrator" --config "${CONFIG}" --once）、launchd に登録してください:
  launchctl bootstrap gui/\$(id -u) "${PLIST}"
止めるとき:
  launchctl bootout gui/\$(id -u)/$LABEL
MSG
