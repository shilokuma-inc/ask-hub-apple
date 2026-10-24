#!/bin/bash
# GitHub にある既存のリポジトリを担当 PC に入れる準備をする。オーケストレーターの addRepositoryCommand から呼ぶ。
#   usage: add-repo.sh <owner/repo> <checkout のパス> <依頼を受けた担当リポジトリの checkout のパス>
#
# 1. リポジトリを確かめる（見つからない・アーカイブ済み・push の権限が無い・develop が無いなら断る）
# 2. checkout のパスに同じ origin の checkout があればそのまま使い（作業ツリー・ブランチ・未コミットの変更には触らない）、無ければ clone する
# 3. AskHub のラベルを作り、Discussions を有効にする（できなければ人に知らせて続ける）
# 4. ralph-kit の中継と CLAUDE.md の「ralph-loop による自律開発」の節を、一時 worktree（origin/develop）で入れて develop に push する。
#    develop に push できなければ askhub/ralph-kit-relay ブランチから develop 宛ての PR を作る
# ralph-kit は、依頼を受けた担当リポジトリの scripts/ralph-kit.sh が取る版を使う。
#
# 人に伝える行は `ASKHUB_RESULT: …`、失敗の理由は `ASKHUB_ERROR: …` で出す（依頼 Issue にはこの行だけが書かれる。
# ローカルのパスを含めない）。前提を満たさず、やり直しても成功しないときは終了コード 3 で終わる。
# 途中で失敗しても、やり直すと続きから進む（clone 済み・ラベル作成済み・中継が develop に入っている、を見て飛ばす）。
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

REPOSITORY="${1:-}"
CHECKOUT="${2:-}"
HUB="${3:-}"
BRANCH="develop"
RELAY_BRANCH="askhub/ralph-kit-relay"
RELAY_TITLE="[chore] ralph-kit の中継を入れる"
RELAY_PR_TITLE="【CHORE】ralph-kit の中継を入れる"
SECTION="## ralph-loop による自律開発"
SNIPPET_BEGIN="<!-- ralph-kit:snippet begin"
SNIPPET_END="<!-- ralph-kit:snippet end -->"

result() { echo "ASKHUB_RESULT: $*"; }
reject() { echo "ASKHUB_ERROR: $*"; exit 3; }
fail() { echo "ASKHUB_ERROR: $*"; exit 1; }

if [[ -z "$REPOSITORY" || -z "$CHECKOUT" || -z "$HUB" ]]; then
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  exit 64
fi
# 依頼の値はアプリとオーケストレーターでも確かめているが、シェルに渡す前にもう一度絞る
NAME_PATTERN='^[A-Za-z0-9_.][A-Za-z0-9_.-]*/[A-Za-z0-9_.][A-Za-z0-9_.-]*$'
[[ "$REPOSITORY" =~ $NAME_PATTERN ]] || reject "リポジトリ名が不正です: $REPOSITORY"
[[ "$CHECKOUT" == /* && "$HUB" == /* ]] || reject "checkout のパスは絶対パスにしてください"
CHECKOUT="${CHECKOUT%/}"
for command in gh git; do
  command -v "$command" >/dev/null 2>&1 || fail "$command が見つかりません"
done
# ラベル・Discussions の準備は create-repo.sh と共通（install.sh は同じ場所に askhub-repo-setup として置く）
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
for lib in "$SCRIPT_DIR/askhub-repo-setup" "$SCRIPT_DIR/repo-setup.sh"; do
  if [[ -f "$lib" ]]; then
    # shellcheck source=repo-setup.sh
    source "$lib"
    break
  fi
done
declare -F askhub_create_labels >/dev/null || fail "askhub-repo-setup が見つかりません（scripts/orchestrator/install.sh を流し直してください）"
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# 1. リポジトリを確かめる。見つからない（権限が無い）のと、通信の失敗（やり直せば進む）を分ける
if ! info=$(gh api "repos/$REPOSITORY" --jq '[.archived, .permissions.push, .has_discussions] | @tsv' 2>&1); then
  if [[ "$info" == *"HTTP 404"* || "$info" == *"Not Found"* ]]; then
    reject "$REPOSITORY が見つかりません（名前と、この PC の gh の権限を確かめてください）"
  fi
  fail "$REPOSITORY の情報を取得できませんでした"
fi
IFS=$'\t' read -r archived can_push has_discussions <<<"$info"
[[ "$archived" != true ]] || reject "$REPOSITORY はアーカイブ済みです"
[[ "$can_push" == true ]] || reject "この PC の gh には $REPOSITORY への push の権限がありません"
if ! branch_info=$(gh api "repos/$REPOSITORY/branches/$BRANCH" --jq .name 2>&1); then
  if [[ "$branch_info" == *"HTTP 404"* || "$branch_info" == *"Not Found"* ]]; then
    reject "$REPOSITORY に $BRANCH ブランチがありません。AskHub のループは $BRANCH を起点にします。$BRANCH を作ってから依頼し直してください"
  fi
  fail "$REPOSITORY の $BRANCH ブランチを確かめられませんでした"
fi

# 2. checkout。決まった場所に同じ origin の checkout があれば、そのまま使う
if [[ -e "$CHECKOUT" ]]; then
  [[ -d "$CHECKOUT" ]] || reject "clone 先にファイルがあります（$(basename "$CHECKOUT")）。移動してから依頼し直してください"
  toplevel=$(git -C "$CHECKOUT" rev-parse --show-toplevel 2>/dev/null || true)
  if [[ -z "$toplevel" || "$toplevel" != "$(cd "$CHECKOUT" && pwd -P)" ]]; then
    reject "clone 先に git の checkout ではないディレクトリがあります（$(basename "$CHECKOUT")）。移動してから依頼し直してください"
  fi
  # insteadOf で書き換える前の、設定に書かれた URL を、ssh と https のどちらでも末尾の owner/repo で比べる
  origin=$(git -C "$CHECKOUT" config --get remote.origin.url 2>/dev/null || true)
  origin_name=$(printf '%s' "$origin" | sed -E 's#^.*github\.com[:/]##; s#\.git$##')
  if [[ "$(lower "$origin_name")" != "$(lower "$REPOSITORY")" ]]; then
    reject "clone 先に別のリポジトリの checkout があります（$(basename "$CHECKOUT")）。移動してから依頼し直してください"
  fi
  result "この PC に既にある $REPOSITORY の checkout を使います"
else
  mkdir -p "$(dirname "$CHECKOUT")"
  gh repo clone "$REPOSITORY" "$CHECKOUT" -- --branch "$BRANCH" >/dev/null 2>&1 \
    || fail "$REPOSITORY を clone できませんでした"
  result "$REPOSITORY をこの PC に clone しました"
fi

# 3. AskHub のラベルと Discussions。既存のリポジトリは管理者でない organization にあることがあるので、
#    Discussions を有効にできなくても失敗にせず、人に知らせて続ける（依頼から Discussion を作るときにもオーケストレーターが確かめる）
askhub_create_labels "$REPOSITORY"
if [[ "$has_discussions" == true ]]; then
  has_ideas=$(askhub_has_ideas_category "$REPOSITORY" 1)
  discussions=true
elif askhub_enable_discussions "$REPOSITORY" 2>/dev/null; then
  has_ideas=$(askhub_has_ideas_category "$REPOSITORY")
  discussions=true
  result "Discussions を有効にしました"
else
  discussions=false
  result "Discussions を有効にできませんでした。リポジトリの管理者に、GitHub の Settings で Discussions を有効にしてもらってください（依頼からの Discussion の作成に使います）"
fi
if [[ "$discussions" == true && "$has_ideas" != true ]]; then
  result "Discussions にカテゴリ「Ideas」がありません。GitHub の Discussions で作ってください（依頼からの Discussion の作成に使います）"
fi

# 4. ralph-kit の中継。kit の場所は、依頼を受けた担当リポジトリの中継に聞く
[[ -x "$HUB/scripts/ralph-kit.sh" ]] || fail "依頼を受けた担当リポジトリに scripts/ralph-kit.sh がありません"
KIT=$("$HUB/scripts/ralph-kit.sh" path) || fail "ralph-kit を取得できませんでした"
[[ -x "$KIT/install.sh" && -f "$KIT/templates/CLAUDE.snippet.md" ]] || fail "ralph-kit に install.sh か templates/CLAUDE.snippet.md がありません"

# メインの checkout には人の作業中の変更がありうるので、origin/develop の一時 worktree の中でコミットする
TEMP_DIR=""
cleanup() {
  if [[ -n "$TEMP_DIR" ]]; then
    git -C "$CHECKOUT" worktree remove --force "$TEMP_DIR/relay" >/dev/null 2>&1 || true
    rm -rf "$TEMP_DIR"
    git -C "$CHECKOUT" worktree prune >/dev/null 2>&1 || true
  fi
  return 0
}
trap cleanup EXIT
# 制限時間を過ぎたオーケストレーターの SIGTERM でも、EXIT の trap（後片付け）を走らせてから終わる
trap 'exit 143' TERM
git -C "$CHECKOUT" fetch --quiet origin "$BRANCH" || fail "$REPOSITORY の $BRANCH を取得できませんでした"
BASE=$(git -C "$CHECKOUT" rev-parse FETCH_HEAD)
TEMP_DIR=$(mktemp -d)
RELAY="$TEMP_DIR/relay"
git -C "$CHECKOUT" worktree add --quiet --detach "$RELAY" "$BASE" >/dev/null 2>&1 \
  || fail "中継を入れるための作業場所を作れませんでした"

# CLAUDE.md に節が無ければ、kit の雛形の節（見出しから end の目印まで。先頭の HTML コメントは除く）を末尾に足す
CLAUDE_MD="$RELAY/CLAUDE.md"
if [[ ! -f "$CLAUDE_MD" ]] || ! grep -qxF "$SECTION" "$CLAUDE_MD"; then
  snippet=$(awk -v section="$SECTION" -v end="$SNIPPET_END" '$0 == section { f = 1 } f { print } f && $0 == end { exit }' \
    "$KIT/templates/CLAUDE.snippet.md")
  [[ -n "$snippet" ]] || fail "ralph-kit の templates/CLAUDE.snippet.md から節を読めません"
  if [[ -s "$CLAUDE_MD" ]]; then
    # 末尾に改行が無ければ足してから、空行を挟んで節を続ける
    [[ -z "$(tail -c 1 "$CLAUDE_MD")" ]] || echo >> "$CLAUDE_MD"
    printf '\n%s\n' "$snippet" >> "$CLAUDE_MD"
  else
    printf '%s\n' "$snippet" > "$CLAUDE_MD"
  fi
elif ! grep -qF "$SNIPPET_BEGIN" "$CLAUDE_MD"; then
  result "CLAUDE.md の「ralph-loop による自律開発」の節に ralph-kit:snippet の目印が無いため、節は書き換えていません。節の本文を ralph-kit の templates/CLAUDE.snippet.md の目印の範囲に置き換えてください"
fi
# kit の install.sh は渡した checkout だけに書き込む（コミットはしない）
"$KIT/install.sh" "$RELAY" >&2 \
  || reject "ralph-kit の install.sh が失敗しました（CLAUDE.md の ralph-kit:snippet の目印が begin・end の順に 1 つずつあるか確かめてください）"

git -C "$RELAY" add -A
if git -C "$RELAY" diff --cached --quiet; then
  result "ralph-kit の中継は $BRANCH に入っています"
  exit 0
fi
git -C "$RELAY" commit --quiet -m "$RELAY_TITLE" || fail "中継をコミットできませんでした"
if git -C "$RELAY" push --quiet origin "HEAD:refs/heads/$BRANCH" 2>/dev/null; then
  result "ralph-kit の中継と CLAUDE.md の節を $BRANCH に push しました"
  exit 0
fi

# develop に push できない（ブランチの保護・PR 必須・gh に workflow の権限が無いなど）。ブランチから PR にする。
# やり直しで既に開いている PR があれば、それを使い回す
existing_pr=$(gh pr list --repo "$REPOSITORY" --head "$RELAY_BRANCH" --base "$BRANCH" --state open \
  --json url --jq '.[0].url // ""' 2>/dev/null) || fail "$REPOSITORY の PR を確かめられませんでした"
if [[ -n "$existing_pr" ]]; then
  result "$BRANCH に直接 push できなかったので PR にしました: ${existing_pr}。マージするとループを回せます"
  exit 0
fi
# 前回 push したが PR を作れなかったやり直しで、ブランチの中身が同じなら push し直さない（コミットの時刻が違い、fast-forward にならないため）
if git -C "$RELAY" fetch --quiet origin "refs/heads/$RELAY_BRANCH" 2>/dev/null \
  && [[ "$(git -C "$RELAY" rev-parse 'FETCH_HEAD^{tree}')" == "$(git -C "$RELAY" rev-parse 'HEAD^{tree}')" ]]; then
  echo "$RELAY_BRANCH は push 済みです"
else
  git -C "$RELAY" push --quiet origin "HEAD:refs/heads/$RELAY_BRANCH" 2>/dev/null \
    || reject "$BRANCH にも $RELAY_BRANCH ブランチにも push できませんでした（ブランチの保護と、gh の権限に workflow があるかを確かめてください。$RELAY_BRANCH が既にあれば消してから依頼し直してください）"
fi
PR_BODY="$TEMP_DIR/pr-body.md"
cat > "$PR_BODY" <<BODY
AskHub の「担当に入れる」依頼で、ralph-kit の中継（\`scripts/ralph-*.sh\`・\`scripts/askhub-manual.sh\`・\`.claude/ralph/\`・\`.github/workflows/close-goal-discussion.yml\`）と、
CLAUDE.md の「ralph-loop による自律開発」の節を入れます。$BRANCH に直接 push できなかったため PR にしました。

マージすると、このリポジトリで AskHub のループを回せます。（askhub-orchestrator が作成）
BODY
pr_url=$(gh pr create --repo "$REPOSITORY" --base "$BRANCH" --head "$RELAY_BRANCH" --title "$RELAY_PR_TITLE" \
  --body-file "$PR_BODY" 2>/dev/null) \
  || reject "$BRANCH に直接 push できず、$RELAY_BRANCH からの PR も作れませんでした（gh の権限を確かめてください）"
result "$BRANCH に直接 push できなかったので PR にしました: ${pr_url}。マージするとループを回せます"
