#!/bin/bash
# epic の最終 PR（epic → develop）のコンフリクトを解消する。オーケストレーターが conflictCommand として呼ぶ。
#   usage: askhub-resolve-conflict <owner/repo> <checkoutPath> <headBranch> <baseBranch> <pullRequest>
#
# ループの作業場所（制御用 worktree・スロット）とは別の一時 worktree で、head に base を取り込む。
#   - コンフリクトしなければ、そのままマージコミットを head に push する
#   - コンフリクトしたら claude -p に解消させ、CLAUDE.md の検証コマンドを通させてからマージコミットを作らせる。
#     コンフリクトの印が残っていないこと・マージが完了していることをこのスクリプトが確かめてから push する
# 最後の行に結果を出す（オーケストレーターが読む）:
#   ASKHUB_RESULT: merged      … コンフリクトせずに取り込んだ
#   ASKHUB_RESULT: resolved    … コンフリクトを解消して取り込んだ
#   ASKHUB_RESULT: unresolved <理由> … 人の対応が要る（終了コード 2）
#
# 環境変数:
#   ASKHUB_CLAUDE    claude の実行ファイル（既定: claude）
#   ASKHUB_LOG_DIR   ログの置き場所（既定: ~/Library/Logs/askhub/loops）
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

REPOSITORY="${1:-}"
CHECKOUT="${2:-}"
HEAD_BRANCH="${3:-}"
BASE_BRANCH="${4:-}"
PULL_REQUEST="${5:-}"
if [[ -z "$REPOSITORY" || -z "$CHECKOUT" || -z "$HEAD_BRANCH" || -z "$BASE_BRANCH" || ! "$PULL_REQUEST" =~ ^[0-9]+$ ]]; then
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  exit 64
fi

CLAUDE_BIN="${ASKHUB_CLAUDE:-claude}"
LOG_DIR="${ASKHUB_LOG_DIR:-$HOME/Library/Logs/askhub/loops}"
REPO_NAME="${REPOSITORY#*/}"

log() { echo "[$(date '+%F %T')] [resolve-conflict ${REPOSITORY}#${PULL_REQUEST}] $*"; }
unresolved() {
  log "$*"
  echo "ASKHUB_RESULT: unresolved $*"
  exit 2
}

[[ -d "$CHECKOUT/.git" || -f "$CHECKOUT/.git" ]] || unresolved "checkout が見つかりません: ${CHECKOUT}"
mkdir -p "$LOG_DIR"
CLAUDE_LOG="$LOG_DIR/${REPO_NAME}-conflict-${PULL_REQUEST}-$(date +%Y%m%d-%H%M%S).log"

# ループの制御用 worktree・スロットには触れない。ralph-loop の Stop hook に捕まらないよう、
# state ファイルの無い一時 worktree で作業する
TMP=$(mktemp -d "${TMPDIR:-/tmp}/askhub-conflict-XXXXXX")
WORKTREE="$TMP/worktree"
cleanup() {
  git -C "$CHECKOUT" worktree remove --force "$WORKTREE" >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT

git -C "$CHECKOUT" fetch -q origin "$HEAD_BRANCH" "$BASE_BRANCH" || unresolved "origin から ${HEAD_BRANCH} / ${BASE_BRANCH} を取得できませんでした"
HEAD_SHA=$(git -C "$CHECKOUT" rev-parse "origin/$HEAD_BRANCH")
git -C "$CHECKOUT" worktree add -q --detach "$WORKTREE" "$HEAD_SHA"

push() {
  # 取り込みの間に head が進んでいたら上書きしない（先行のコミットを消さない）
  git -C "$WORKTREE" push -q --force-with-lease="refs/heads/${HEAD_BRANCH}:${HEAD_SHA}" origin "HEAD:refs/heads/${HEAD_BRANCH}" \
    || unresolved "${HEAD_BRANCH} に push できませんでした（取り込みの間に ${HEAD_BRANCH} が更新された可能性があります）"
}

if git -C "$WORKTREE" merge -q --no-edit "origin/$BASE_BRANCH" >/dev/null 2>&1; then
  push
  log "${BASE_BRANCH} をコンフリクトなしで取り込み、${HEAD_BRANCH} に push しました（$(git -C "$WORKTREE" rev-parse --short HEAD)）"
  echo "ASKHUB_RESULT: merged"
  exit 0
fi

CONFLICTS=$(git -C "$WORKTREE" diff --name-only --diff-filter=U)
[[ -n "$CONFLICTS" ]] || unresolved "${BASE_BRANCH} の取り込みに失敗しましたが、コンフリクトしたファイルがありません"
log "コンフリクトしたファイル: $(printf '%s' "$CONFLICTS" | tr '\n' ' ')。claude に解消させます（ログ: ${CLAUDE_LOG}）"

PROMPT=$(cat <<EOF
あなたは、epic の最終 PR（${REPOSITORY}#${PULL_REQUEST}、${HEAD_BRANCH} → ${BASE_BRANCH}）のコンフリクトを解消する担当です。
作業ディレクトリは一時 worktree（${WORKTREE}）で、${HEAD_BRANCH} に origin/${BASE_BRANCH} を取り込む git merge がコンフリクトして止まっています。

コンフリクトしているファイル:
${CONFLICTS}

手順:
1. まず CLAUDE.md（と LEARNINGS.md があればそれ）を読む
2. 各ファイルのコンフリクトを解消する。${HEAD_BRANCH} 側（epic の変更）と ${BASE_BRANCH} 側（develop に先に入った変更）の両方の意図を残す。
   どちらかを丸ごと捨てない。意図がぶつかって両立できないときは、解消せずに下の unresolved で理由を書く
3. CLAUDE.md の「ビルド・検証」のコマンドを実行し、すべて通す（通らなければ直す。直せなければ unresolved）
4. 解消したファイルを git add し、git commit --no-edit でマージを完了させる
5. 次はしない: git push、ブランチの切り替え、git merge --abort、コンフリクトと無関係なファイルの変更

最後の行に、次のどちらかだけを出力する（ほかの文は前の行に書く）:
ASKHUB_RESULT: resolved
ASKHUB_RESULT: unresolved <人に伝える理由（1 行）>
EOF
)

set +e
OUTPUT=$(cd "$WORKTREE" && "$CLAUDE_BIN" -p --permission-mode bypassPermissions "$PROMPT" </dev/null 2>&1 | tee -a "$CLAUDE_LOG")
STATUS=$?
set -e
# 利用上限で終わったときは、オーケストレーターが末尾から解除の時刻を読む
printf '%s\n' "$OUTPUT" | tail -n 5
[[ $STATUS -eq 0 ]] || unresolved "claude が失敗しました（終了コード ${STATUS}。${CLAUDE_LOG}）"

RESULT=$(printf '%s\n' "$OUTPUT" | sed -n 's/^ASKHUB_RESULT: *//p' | tail -1)
case "$RESULT" in
  resolved) ;;
  unresolved*) unresolved "${RESULT#unresolved }" ;;
  *) unresolved "claude の出力から結果を読み取れませんでした（${CLAUDE_LOG}）" ;;
esac

# claude の報告を鵜呑みにせず、マージが完了していてコンフリクトの印が残っていないことを確かめる
[[ ! -e "$(git -C "$WORKTREE" rev-parse --git-path MERGE_HEAD)" ]] || unresolved "マージが完了していません（git commit されていない）"
[[ -z "$(git -C "$WORKTREE" status --porcelain)" ]] || unresolved "コミットしていない変更が残っています"
git -C "$WORKTREE" merge-base --is-ancestor "origin/$BASE_BRANCH" HEAD || unresolved "${BASE_BRANCH} が取り込まれていません"
git -C "$WORKTREE" merge-base --is-ancestor "$HEAD_SHA" HEAD || unresolved "${HEAD_BRANCH} の元のコミットが含まれていません"
# 見るのはコンフリクトしたファイルだけ（もともと印に似た行を含むファイルを誤検知しない）
CONFLICT_FILES=()
while IFS= read -r file; do [[ -n "$file" ]] && CONFLICT_FILES+=("$file"); done <<< "$CONFLICTS"
if git -C "$WORKTREE" grep -n -I -E '^(<<<<<<<|>>>>>>>)( |$)' HEAD -- "${CONFLICT_FILES[@]}" >/dev/null 2>&1; then
  unresolved "コンフリクトの印（<<<<<<< / >>>>>>>）が残っています"
fi

push
log "コンフリクトを解消し、${HEAD_BRANCH} に push しました（$(git -C "$WORKTREE" rev-parse --short HEAD)）"
echo "ASKHUB_RESULT: resolved"
