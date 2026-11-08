#!/bin/bash
# 司令塔をビルドして常時オンの Mac に送り、そこで Developer ID で署名して差し替える（docs/renewal/operations.md の「司令塔の更新」）。
#
#   scripts/commander/deploy.sh [ssh の接続先（既定 macmini）]
#
# 署名の鍵は常時オンの Mac のログインキーチェーンにだけ置く（この Mac には置かない）。
# 署名と差し替えは、常時オンの Mac の LaunchAgent（install-deployer.sh で入れる）がログイン中のセッションで行う
# 送り先のパス（$REMOTE）と SHA-256 は、この Mac で展開してから送る（$HOME だけを常時オンの Mac で展開する）
# shellcheck disable=SC2029
set -euo pipefail

HOST="${1:-macmini}"
cd "$(git rev-parse --show-toplevel)"
REMOTE='Library/Application Support/AskHub/deploy'

swift build -c release --package-path AskHubKit --product askhub-commander
BINARY="AskHubKit/.build/release/askhub-commander"
SUM=$(shasum -a 256 "$BINARY" | awk '{print $1}')

ssh "$HOST" "mkdir -p \"\$HOME/$REMOTE/incoming\""
if ! ssh "$HOST" "launchctl print gui/\$(id -u)/jp.shilokuma.askhub.deploy >/dev/null 2>&1"; then
    echo "常時オンの Mac に jp.shilokuma.askhub.deploy がありません。次を常時オンの Mac のログイン中の端末で 1 回流してください:" >&2
    scp -q scripts/commander/sign-and-install.sh scripts/commander/install-deployer.sh "$HOST:$REMOTE/"
    echo "  bash ~/'$REMOTE'/install-deployer.sh" >&2
    exit 1
fi
scp -q "$BINARY" "$HOST:$REMOTE/incoming/askhub-commander"
ssh "$HOST" "rm -f \"\$HOME/$REMOTE/last.log\"; echo $SUM >\"\$HOME/$REMOTE/request\""

result=""
for _ in $(seq 1 90); do
    result=$(ssh "$HOST" "cat \"\$HOME/$REMOTE/last.log\" 2>/dev/null" || true)
    case "$result" in *status=*) break ;; esac
    sleep 2
done
echo "$result"
case "$result" in
    *status=ok*) exit 0 ;;
    *status=*) exit 1 ;;
    *) echo "常時オンの Mac から結果が返ってこない（初めての署名なら、常時オンの Mac の画面で codesign の Keychain の確認を「常に許可」にする）" >&2; exit 1 ;;
esac
