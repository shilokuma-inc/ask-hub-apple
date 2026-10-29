#!/bin/bash
# ループの準備（askhub-start-loop）から呼ぶ、zip の添付の展開。
#   usage: extract-attachment-zip.sh <zip> <展開先>
#
# 規則（docs/protocol.md の「zip の展開」）をシェルで作り直さず、askhub-orchestrator の extract-zip（Swift の AttachmentZipExtractor）を呼ぶ中継。
# 展開先は先に消して作り直すので、添付の置き場所（ASKHUB_ATTACHMENTS_DIR）の下の、リンクを解いた名前が .d で終わるディレクトリだけを受け付ける。
# 置き場所の外（/・ホーム・リポジトリの中を含む）・リンクを解くと外へ出るもの・展開先そのものがシンボリックリンクのもの・. か .. を含むもの・
# 制御文字を含むものは断る。置き場所がホームと同じか上の階層・git のリポジトリの中でも断る（askhub-orchestrator の extract-zip も同じ確かめをする）。
#
# 出力（標準出力。タブ区切り。形は askhub-orchestrator の AttachmentZipCommand）:
#   extracted<TAB><展開先><TAB><読めるファイルの数><TAB><素材の数><TAB><展開しなかった項目の数>
#   readable<TAB><MIME タイプ><TAB><バイト数><TAB><zip の中のパス><TAB><展開先の絶対パス>
#   material<TAB><バイト数><TAB><zip の中のパス><TAB><展開先の絶対パス>
#   skipped<TAB><理由><TAB><zip の中の名前>
#   展開できない・断った・引数が誤っているときは failed<TAB><理由> の 1 行（理由の制御文字は空白にする）で、終了コードは 0 以外
#   （65: zip を展開できない、64: 引数の誤り、69: askhub-orchestrator が無い、77: 展開先を断った）
#
# 環境変数（省略可）:
#   ASKHUB_ORCHESTRATOR      呼ぶ askhub-orchestrator（既定: このスクリプトと同じ場所の askhub-orchestrator。
#                            無ければリポジトリの AskHubKit/.build の release → debug のビルド）
#   ASKHUB_ATTACHMENTS_DIR   添付の置き場所の親（既定: ~/Library/Caches/askhub/attachments。start-loop.sh と同じ）
set -euo pipefail

# 名前とパスの比較は UTF-8 のバイト単位で行う（docs/protocol.md の「zip の展開」）
export LC_ALL=C

failed() {
  local status="$1"
  shift
  # 理由に入れた値（展開先など）の改行・タブで、failed の次の行を足させない
  printf 'failed\t%s\n' "$(printf '%s' "$*" | tr '\000-\037\177' ' ')"
  exit "$status"
}

if [[ $# -ne 2 || -z "${1:-}" || -z "${2:-}" ]]; then
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  failed 64 "引数は <zip> <展開先> の 2 つです"
fi
ZIP="$1"
DEST="$2"

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
ORCHESTRATOR="${ASKHUB_ORCHESTRATOR:-}"
if [[ -z "$ORCHESTRATOR" ]]; then
  for candidate in \
    "$SCRIPT_DIR/askhub-orchestrator" \
    "$SCRIPT_DIR/../../AskHubKit/.build/release/askhub-orchestrator" \
    "$SCRIPT_DIR/../../AskHubKit/.build/debug/askhub-orchestrator"; do
    if [[ -x "$candidate" ]]; then
      ORCHESTRATOR="$candidate"
      break
    fi
  done
fi
if [[ -z "$ORCHESTRATOR" || ! -x "$ORCHESTRATOR" ]]; then
  failed 69 "askhub-orchestrator が見つかりません（scripts/orchestrator/install.sh で入れるか、ASKHUB_ORCHESTRATOR で指定してください）"
fi

# --- 展開先を確かめる（展開先は消して作り直されるので、置き場所の外を指していたら呼ばない） ---
ROOT="${ASKHUB_ATTACHMENTS_DIR:-$HOME/Library/Caches/askhub/attachments}"
[[ -d "$ROOT" ]] || failed 77 "添付の置き場所がありません: ${ROOT}"
REAL_ROOT=$(cd "$ROOT" && pwd -P) || failed 77 "添付の置き場所を開けません: ${ROOT}"
REAL_HOME=$(cd "$HOME" && pwd -P)
if [[ "$REAL_ROOT" == "/" || "$REAL_ROOT" == "$REAL_HOME" ]]; then
  failed 77 "添付の置き場所が / かホームです: ${REAL_ROOT}"
fi

case "$DEST" in
  /*) ;;
  *) failed 77 "展開先は絶対パスで指定してください: ${DEST}" ;;
esac
if [[ "$DEST" == *[[:cntrl:]]* ]]; then
  failed 77 "展開先に制御文字があります"
fi
# 末尾の / を落としてから、. と .. の要素を断る（解決する前の文字列で見る）
while [[ "$DEST" == */ && "$DEST" != "/" ]]; do
  DEST="${DEST%/}"
done
case "/$DEST/" in
  */./* | */../*) failed 77 "展開先に . か .. の要素があります: ${DEST}" ;;
esac
# 展開先そのものがリンクだと、リンクの先（置き場所の中の上の階層など）が消される
if [[ -L "$DEST" ]]; then
  failed 77 "展開先がシンボリックリンクです: ${DEST}"
fi

# 展開先は無いことが多いので、あるところまで上ってシンボリックリンクを解き、残りを足して比べる
EXISTING="$DEST"
REST=""
while [[ ! -e "$EXISTING" && ! -L "$EXISTING" ]]; do
  REST="/$(basename "$EXISTING")$REST"
  EXISTING=$(dirname "$EXISTING")
done
REAL_EXISTING=$(cd "$EXISTING" 2>/dev/null && pwd -P) || failed 77 "展開先の親がディレクトリではありません: ${EXISTING}"
REAL_DEST="${REAL_EXISTING%/}$REST"
# 名前と置き場所の中かは、リンクを解いた後のパス（実際に消して作り直すもの）で確かめる
case "$REAL_DEST" in
  *?.d) ;;
  *) failed 77 "展開先の名前は .d で終わるものにしてください（<ファイル名>.d）: ${REAL_DEST}" ;;
esac
if [[ "$REAL_DEST" != "$REAL_ROOT"/?* ]]; then
  failed 77 "展開先が添付の置き場所（${REAL_ROOT}）の外です: ${REAL_DEST}"
fi
# 置き場所がリポジトリの中に向けられていたら、checkout のファイルを消しかねないので断る。
# 展開先が既にあるときは前の展開の残りで、zip の中の .git があるかもしれないので、親から確かめる
GIT_CHECK_DIR="$REAL_EXISTING"
[[ -z "$REST" ]] && GIT_CHECK_DIR=$(dirname "$REAL_EXISTING")
if [[ "$(unset GIT_DIR GIT_WORK_TREE; git -C "$GIT_CHECK_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" == "true" ]]; then
  failed 77 "展開先が git のリポジトリの中です: ${REAL_DEST}"
fi

exec "$ORCHESTRATOR" extract-zip "$ZIP" "$REAL_DEST"
