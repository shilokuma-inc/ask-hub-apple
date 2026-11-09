#!/bin/bash
# 常時オンの Mac のログイン中のセッション（LaunchAgent `jp.shilokuma.askhub.deploy`）で動き、
# 送られてきた司令塔を Developer ID で署名して差し替える（docs/renewal/operations.md の「司令塔の更新」）。
#
# ssh のセッションからはログインキーチェーンの署名の鍵を使えない（codesign が errSecInternalComponent で止まる）ので、
# ssh で置いた依頼（deploy/request。中身は送ったプログラムの SHA-256）を、ログイン中のセッションのこのスクリプトが拾う。
# 同じ Developer ID と識別子で署名し続けるので、Keychain の「常に許可」は入れ替えても続く
set -euo pipefail

TEAM="XU74X3434S"
IDENTIFIER="jp.shilokuma.askhub.commander"
LABEL="jp.shilokuma.askhub.commander"
ROOT="$HOME/Library/Application Support/AskHub"
DEPLOY="$ROOT/deploy"
INCOMING="$DEPLOY/incoming/askhub-commander"
REQUEST="$DEPLOY/request"
BINARY="$ROOT/bin/askhub-commander"
LOG="$DEPLOY/last.log"

[ -f "$REQUEST" ] || exit 0
exec >"$LOG" 2>&1
trap 'echo "status=failed（$LINENO 行目で止まった）"' ERR
echo "[$(date -u +%FT%TZ)] 署名と差し替えを始める"

expected=$(tr -d '[:space:]' <"$REQUEST")
rm -f "$REQUEST"
if [ ! -f "$INCOMING" ]; then
    echo "status=failed（送られたプログラムが無い）"
    exit 1
fi
actual=$(shasum -a 256 "$INCOMING" | awk '{print $1}')
if [ "$expected" != "$actual" ]; then
    echo "status=failed（送られたプログラムの SHA-256 が依頼と合わない）"
    exit 1
fi

identity=$(security find-identity -v -p codesigning | awk -v team="($TEAM)" '/Developer ID Application/ && index($0, team) { print $2; exit }')
if [ -z "$identity" ]; then
    echo "status=failed（Developer ID Application（${TEAM}）の証明書がログインキーチェーンに無い）"
    exit 1
fi

codesign --force --sign "$identity" --identifier "$IDENTIFIER" --timestamp "$INCOMING"
codesign --verify --strict "$INCOMING"
# grep -q は見つけた時点で読むのをやめ、codesign が書き込みの途中で止まって失敗するので、pipefail で全体が失敗になる。先に受けてから調べる
signature=$(codesign -dv "$INCOMING" 2>&1)
if [[ "$signature" != *"TeamIdentifier=${TEAM}"* ]]; then
    echo "status=failed（署名のチームが $TEAM でない）"
    exit 1
fi

mkdir -p "$(dirname "$BINARY")"
if [ -f "$BINARY" ]; then
    cp -p "$BINARY" "$BINARY.prev"
fi
mv "$INCOMING" "$BINARY.new"
mv "$BINARY.new" "$BINARY"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "status=ok（$actual を署名して差し替え、司令塔を再起動した）"
