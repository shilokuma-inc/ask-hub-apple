#!/bin/bash
# 担当リポジトリを AskHub で使う準備（ラベル・Discussions）の共通の処理。create-repo.sh と add-repo.sh が source する。
# install.sh が、呼ぶスクリプトと同じ場所に askhub-repo-setup として置く（単独では実行しない）。
# 関数は gh を使い、引数のリポジトリ（owner/repo）だけに書き込む。

# AskHub のラベル（scripts/ralph-setup.sh と同じ）を作る。既にあるもの・作れないものは飛ばす
askhub_create_labels() {
  local repository="$1" name color description
  while IFS='|' read -r name color description; do
    gh label create "$name" --repo "$repository" --color "$color" --description "$description" >/dev/null 2>&1 || true
  done <<'LABELS'
needs-answer|D93F0B|人間の回答を待っている質問がある
ready-for-loop|0E8A16|Discussion の回答が確定し、ループを始めてよい
manual-loop|C5DEF5|この Discussion のループは手で回す（オーケストレーターは起動しない）
idea-request|5319E7|アプリから出した新機能の依頼
decision-log|1D76DB|epic ごとの仮決め一覧（判断ログ）
needs-verify|FBCA04|実機・実データでの確認が必要
epic-final|B60205|epic から develop への最終 PR
LABELS
}

# Discussions を有効にする。有効にできなければ失敗（戻り値 1）
askhub_enable_discussions() {
  gh repo edit "$1" --enable-discussions >/dev/null
}

# カテゴリ「Ideas」があれば true、無ければ false を出す（依頼から質問付きの Discussion を作るときに使う）。
# 既定のカテゴリは Discussions を有効にした直後に作られるので、第 2 引数の回数（既定 10）まで 2 秒おきに確かめ直す
askhub_has_ideas_category() {
  local repository="$1" attempts="${2:-10}" has_ideas="" i
  # shellcheck disable=SC2016 # GraphQL の変数で、シェルでは展開しない
  local query='query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) { discussionCategories(first: 50) { nodes { name } } } }'
  for ((i = 1; i <= attempts; i++)); do
    has_ideas=$(gh api graphql -f query="$query" -f owner="${repository%%/*}" -f name="${repository#*/}" \
      --jq '[.data.repository.discussionCategories.nodes[].name] | index("Ideas") != null' 2>/dev/null || true)
    [[ "$has_ideas" == true ]] && break
    (( i < attempts )) && sleep 2
  done
  if [[ "$has_ideas" == true ]]; then echo true; else echo false; fi
}
