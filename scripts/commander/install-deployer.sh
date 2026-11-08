#!/bin/bash
# 常時オンの Mac に、司令塔の署名と差し替えをする LaunchAgent（jp.shilokuma.askhub.deploy）を入れる。
# 常時オンの Mac のログイン中の端末で 1 回だけ流す（`scripts/commander/deploy.sh` が ssh でこのスクリプトと一緒に送る）
set -euo pipefail

LABEL="jp.shilokuma.askhub.deploy"
DEPLOY="$HOME/Library/Application Support/AskHub/deploy"
SCRIPT="$DEPLOY/sign-and-install.sh"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

mkdir -p "$DEPLOY/incoming" "$HOME/Library/LaunchAgents"
cp "$(dirname "$0")/sign-and-install.sh" "$SCRIPT"
chmod 700 "$SCRIPT"
cat >"$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$SCRIPT</string>
    </array>
    <key>WatchPaths</key>
    <array>
        <string>$DEPLOY/request</string>
    </array>
</dict>
</plist>
PLIST
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "$LABEL を入れました（$PLIST）"
