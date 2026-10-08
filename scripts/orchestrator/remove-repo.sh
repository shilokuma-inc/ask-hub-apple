#!/bin/bash
# 担当から外すリポジトリのローカルの作業場所を消す。オーケストレーターの removeRepositoryCommand から呼ぶ。
#   usage: remove-repo.sh [--force] <checkout のパス> <制御用 worktree のパス>
#
# 消すもの（checkout の隣にあるもの。<stem> はディレクトリ名から -ios を除いたもの）:
#   - checkout と、ループの worktree（<stem>-ralph-ctl / -ralph-a / -ralph-b）
#   - xcodebuild のラッパーなどが作る DerivedData（<stem>-ralph-dd*・<ディレクトリ名>-ralph-dd*・<ディレクトリ名>-DerivedData）
#   - ~/Library/Developer/Xcode/DerivedData のうち、消す場所のプロジェクトのもの
# 制御用 worktree の .claude/ は、消す前に ASKHUB_ARCHIVE_DIR（既定: ~/Library/Logs/askhub/archive）へ退避する。
#
# --force を付けなければ、消す前に次を確かめ、1 つでもあれば消さずに終了コード 3 で終わる:
#   - 未コミットの変更（ループの作業ファイル .claude/askhub-* と .claude/ralph-*.local.* は除く）
#   - stash
#   - どのリモートにも無いコミットを持つブランチのうち、既定ブランチ（origin）に取り込んでも何も変わらないもの以外
#     （squash merge 済みのブランチは、取り込んでも変わらないので消してよいものとして扱う）
# ループのプロセスが動いていれば、--force でも消さない。
#
# 人に伝える行は `ASKHUB_RESULT: …`、失敗の理由は `ASKHUB_ERROR: …` で出す（依頼 Issue にはこの行だけが書かれる。
# ローカルのパスを含めない）。
set -euo pipefail

unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
      GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX

FORCE=false
if [[ "${1:-}" == "--force" ]]; then
  FORCE=true
  shift
fi
CHECKOUT="${1:-}"
CTL="${2:-}"
ARCHIVE_DIR="${ASKHUB_ARCHIVE_DIR:-$HOME/Library/Logs/askhub/archive}"

result() { echo "ASKHUB_RESULT: $*"; }
reject() { echo "ASKHUB_ERROR: $*"; exit 3; }

if [[ -z "$CHECKOUT" || -z "$CTL" ]]; then
  sed -n '2,3p' "$0" | sed 's/^# //' >&2
  exit 64
fi
# checkout を消すので、その中にいないようにする
cd /

# 取り違えて大きな場所を消さないよう、パスの形を確かめる
CHECKOUT="${CHECKOUT%/}"
CTL="${CTL%/}"
PARENT=$(dirname "$CHECKOUT")
NAME=$(basename "$CHECKOUT")
STEM="${NAME%-ios}"
[[ "$CHECKOUT" == /* && "$CTL" == /* ]] || reject "パスは絶対パスにしてください"
[[ "$CHECKOUT" != "$HOME" && "$PARENT" != "/" && "$NAME" != "." && "$NAME" != ".." ]] \
  || reject "checkout の場所が不正です"
[[ "$(dirname "$CTL")" == "$PARENT" ]] || reject "制御用 worktree が checkout の隣にありません"
SLOT_A="$PARENT/$STEM-ralph-a"
SLOT_B="$PARENT/$STEM-ralph-b"

# ループのプロセスが生きていれば消さない（--force でも）
PID_FILE="$CTL/.claude/askhub-loop.pid"
if [[ -f "$PID_FILE" ]]; then
  pid=$(tr -d '[:space:]' < "$PID_FILE")
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    reject "ループのプロセスが動いています。止めてから依頼し直してください"
  fi
fi

# 消してよいかを確かめる
# worktree などで .git がファイルの checkout も確かめる
if [[ "$FORCE" != true && -e "$CHECKOUT/.git" ]]; then
  problems=()
  for dir in "$CHECKOUT" "$CTL" "$SLOT_A" "$SLOT_B"; do
    [[ -e "$dir/.git" ]] || continue
    label=$(basename "$dir")
    changes=$(git -C "$dir" status --porcelain --untracked-files=all 2>/dev/null \
      | grep -v -E '^\?\? \.claude/(askhub-[^/]*|ralph-[^/]*\.local\.[^/]*)$' || true)
    [[ -z "$changes" ]] || problems+=("$label に未コミットの変更があります（$(printf '%s\n' "$changes" | wc -l | tr -d ' ') 件）")
  done
  # stash と ブランチは worktree の間で共有されているので、checkout で 1 回だけ確かめる
  if [[ -n "$(git -C "$CHECKOUT" stash list 2>/dev/null)" ]]; then
    problems+=("stash があります")
  fi
  git -C "$CHECKOUT" fetch --quiet --prune origin 2>/dev/null || problems+=("origin から fetch できず、push 済みか確かめられません")
  default=$(git -C "$CHECKOUT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo "origin/develop")
  if base_tree=$(git -C "$CHECKOUT" rev-parse --verify --quiet "$default^{tree}"); then
    while IFS= read -r branch; do
      [[ -n "$branch" ]] || continue
      [[ -n "$(git -C "$CHECKOUT" log --oneline "refs/heads/$branch" --not --remotes -n 1)" ]] || continue
      # 既定ブランチに取り込んでも木が変わらなければ、変更はすべて既定ブランチにある（squash merge 済みなど）
      merged_tree=$(git -C "$CHECKOUT" merge-tree --write-tree "$default" "refs/heads/$branch" 2>/dev/null | head -n 1 || true)
      [[ "$merged_tree" == "$base_tree" ]] || problems+=("ブランチ $branch に push していないコミットがあります")
    done < <(git -C "$CHECKOUT" for-each-ref --format='%(refname:short)' refs/heads/)
  else
    problems+=("$default が無く、push 済みか確かめられません")
  fi
  if [[ ${#problems[@]} -gt 0 ]]; then
    for problem in "${problems[@]}"; do
      echo "ASKHUB_ERROR: $problem"
    done
    echo "ASKHUB_ERROR: 消さずに残しました。push・退避してから依頼し直すか、強制して依頼し直してください"
    exit 3
  fi
fi

# 消す場所。checkout の隣の DerivedData は、ラッパーの命名に合わせて拾う
targets=()
for path in "$CHECKOUT" "$CTL" "$SLOT_A" "$SLOT_B" \
  "$PARENT/$STEM"-ralph-dd "$PARENT/$STEM"-ralph-dd-* \
  "$PARENT/$NAME"-ralph-dd "$PARENT/$NAME"-ralph-dd-* "$PARENT/$NAME"-DerivedData; do
  [[ -e "$path" ]] || continue
  [[ " ${targets[*]-} " == *" $path "* ]] || targets+=("$path")
done
# Xcode の既定の DerivedData は、info.plist の WorkspacePath で消す場所のプロジェクトのものを探す
XCODE_DERIVED="$HOME/Library/Developer/Xcode/DerivedData"
if [[ -d "$XCODE_DERIVED" ]]; then
  for info in "$XCODE_DERIVED"/*/info.plist; do
    [[ -f "$info" ]] || continue
    workspace=$(plutil -extract WorkspacePath raw -o - "$info" 2>/dev/null || true)
    for root in "$CHECKOUT" "$CTL" "$SLOT_A" "$SLOT_B"; do
      if [[ -n "$workspace" && ( "$workspace" == "$root" || "$workspace" == "$root/"* ) ]]; then
        targets+=("$(dirname "$info")")
        break
      fi
    done
  done
fi

if [[ ${#targets[@]} -eq 0 ]]; then
  result "ローカルに消すものはありませんでした"
  exit 0
fi

# 制御用 worktree の goal・playbook・state を退避する（完了した epic の退避と同じ場所）
if [[ -d "$CTL/.claude" ]]; then
  DEST="$ARCHIVE_DIR/$STEM/removed-$(date +%Y%m%d-%H%M%S)"
  mkdir -p "$DEST"
  cp -R "$CTL/.claude" "$DEST/"
  git -C "$CTL" branch --show-current > "$DEST/branch.txt" 2>/dev/null || true
  result "制御用 worktree の .claude/ を担当 PC のアーカイブに退避しました"
fi

kilobytes=$(du -sk "${targets[@]}" 2>/dev/null | awk '{ sum += $1 } END { print sum + 0 }')
for path in "${targets[@]}"; do
  rm -rf "$path"
  echo "消しました: $path"
done
gigabytes=$(awk -v kb="$kilobytes" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }')
result "checkout・ループの worktree・DerivedData を消しました（${#targets[@]} 個、約 ${gigabytes} GB）"
