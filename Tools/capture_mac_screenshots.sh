#!/bin/bash
set -euo pipefail

# App Store 用の Mac のスクリーンショット（APP_DESKTOP など platform が MAC_OS の表示サイズ）を、全言語・全画面ぶん撮る。
#
#   Tools/capture_mac_screenshots.sh APP_DESKTOP [ja,en]
#
# Tools/capture_screenshots.sh に Mac の表示サイズを渡すと、このスクリプトに切り替わる。
# macOS には Simulator が無く、GitHub のホストランナーには画面収録の許可が無いので、アプリを起動して画面を撮るのではなく、
# macOS のユニットテスト（AskHubTests/MacScreenshotCaptureTests）の中で、撮影モードと同じ画面
# （ContentView をサンプルデータで、ScreenshotDemo.Scene のタブを開いた状態）をウィンドウに出して PNG にする。
# 撮る画面・言語・寸法・出力先は JSON に書き、TEST_RUNNER_ASKHUB_SCREENSHOT_PLAN でテストに渡す
# （xcodebuild は TEST_RUNNER_ を外した名前でテストのプロセスに渡す。渡さないとテストは飛ばされる）。
#
# 出力先: $SCREENSHOTS_DIR/<表示サイズ>/<言語>/01_….png …（既定は build/screenshots）
# 寸法は AppStore/screenshots.json の sizes の先頭（APP_DESKTOP は 2880x1800）。
#
# 手元で試すときの例（DerivedData は既定でリポジトリの外）:
#
#   SKIP_PACKAGE_PLUGIN_VALIDATION=1 Tools/capture_mac_screenshots.sh APP_DESKTOP ja

DISPLAY_TYPE="${1:?表示サイズ（例: APP_DESKTOP）を指定してください}"
LANGUAGES="${2:-}"

TOOLS_DIR="$(CDPATH='' cd -- "$(dirname "$0")" && pwd)"
cd "$TOOLS_DIR/.."
CONFIG="python3 $TOOLS_DIR/app_store_config.py"

PROJECT="$($CONFIG app project)"
SCHEME="${SCHEME:-$($CONFIG app scheme)}"
SIMULATOR_PREFIX="$($CONFIG app simulatorPrefix)"
# 撮影のテスト。@testable import でアプリの View を使うので、Debug でビルドする（xcodebuild test の既定）
SCREENSHOT_TEST="${SCREENSHOT_TEST:-${SCHEME}Tests/MacScreenshotCaptureTests}"
SCREENSHOTS_DIR="${SCREENSHOTS_DIR:-$PWD/build/screenshots}"
# DerivedData はリポジトリ外に置く（capture_screenshots.sh と同じ理由）
DERIVED_DATA="${DERIVED_DATA:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/${SIMULATOR_PREFIX}MacScreenshotDerivedData}"

if [ "$($CONFIG platform "$DISPLAY_TYPE")" != "MAC_OS" ]; then
    echo "$DISPLAY_TYPE は Mac の表示サイズではないので、このスクリプトでは撮りません（Tools/capture_screenshots.sh を使う）" >&2
    exit 1
fi
if [ -n "$($CONFIG derive-from "$DISPLAY_TYPE")" ]; then
    echo "$DISPLAY_TYPE は deriveFrom で縮めて作る表示サイズなので撮りません（Tools/derive_screenshots.py を使う）" >&2
    exit 1
fi

# project.yml から .xcodeproj を作るリポジトリでは、先に生成する
if [ "$($CONFIG app xcodegen)" = "true" ] && [ ! -d "$PROJECT" ]; then
    command -v xcodegen >/dev/null || brew install xcodegen
    xcodegen generate
fi

WORK="$(mktemp -d)"
# bash 3.2 では unbound variable で止まったとき EXIT トラップに終了コード 0 が渡るので、最後まで到達した印で判定する
FINISHED=0
on_exit() {
    status=$?
    if [ "$status" -eq 0 ] && [ "$FINISHED" -ne 1 ]; then
        status=1
    fi
    rm -rf "$WORK"
    exit "$status"
}
trap on_exit EXIT

# MARK: - 撮影の指定

# プロセス置換・パイプの中で失敗しても set -e では止まらないので、先に取り出しておく
EXPECTED_SIZE="$($CONFIG sizes "$DISPLAY_TYPE" | head -n 1)"
LANGUAGE_LIST="$($CONFIG languages "$LANGUAGES")"
SCENE_LIST="$($CONFIG scenes)"
DESTINATION="$SCREENSHOTS_DIR/$DISPLAY_TYPE"

# 撮り直しのたびに古い画像が混ざらないよう、撮る言語のフォルダは作り直す
while IFS=$'\t' read -r language _rest; do
    rm -rf "${DESTINATION:?}/$language"
done <<<"$LANGUAGE_LIST"
mkdir -p "$DESTINATION"

PLAN="$WORK/plan.json"
python3 - "$EXPECTED_SIZE" "$DESTINATION" "$LANGUAGE_LIST" "$SCENE_LIST" > "$PLAN" <<'PY'
import json, sys
size, destination, language_list, scene_list = sys.argv[1:5]
width, height = (int(value) for value in size.split("x"))
languages = [line.split("\t") for line in language_list.splitlines() if line]
scenes = [line.split("\t") for line in scene_list.splitlines() if line]
json.dump({
    "width": width,
    "height": height,
    "outputDirectory": destination,
    # languages.json の language / appleLanguage / appleLocale / storeLocale の順
    "languages": [{"language": entry[0], "appleLocale": entry[2]} for entry in languages],
    "scenes": [{"file": entry[0], "scene": entry[1]} for entry in scenes],
}, sys.stdout, ensure_ascii=False)
PY
echo "撮影の指定: ${EXPECTED_SIZE}・$(printf '%s\n' "$LANGUAGE_LIST" | cut -f1 | paste -sd, -)・$(printf '%s\n' "$SCENE_LIST" | wc -l | tr -d ' ') 画面"

# MARK: - 撮影（テストの実行）

PLUGIN_OPTIONS=()
if [ "${SKIP_PACKAGE_PLUGIN_VALIDATION:-0}" = 1 ]; then
    PLUGIN_OPTIONS+=(-skipPackagePluginValidation -skipMacroValidation)
fi

# 署名用の証明書が無いランナーでも動くよう、build.yml の macOS のテストと同じくアドホック署名にし、App Sandbox を外す
# （Sandbox のままだとテストが出力先に書けない）
echo "::group::${SCREENSHOT_TEST} で撮ります"
TEST_RUNNER_ASKHUB_SCREENSHOT_PLAN="$PLAN" xcodebuild test \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    -only-testing:"$SCREENSHOT_TEST" \
    -parallel-testing-enabled NO \
    ${PLUGIN_OPTIONS[@]+"${PLUGIN_OPTIONS[@]}"} \
    -quiet \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    PROVISIONING_PROFILE_SPECIFIER= \
    ENABLE_APP_SANDBOX=NO
echo "::endgroup::"

# MARK: - 仕上げと検証

# ウィンドウの描画はアルファ付きの PNG になり、App Store Connect は受け付けないので描き直す
REMOVE_ALPHA="$WORK/remove_alpha"
xcrun swiftc -O "$TOOLS_DIR/remove_alpha.swift" -o "$REMOVE_ALPHA"
find "$DESTINATION" -name '*.png' -print0 | xargs -0 "$REMOVE_ALPHA"

# 寸法・アルファ・枚数（テストが飛ばされて 1 枚も無いときもここで落ちる）
python3 "$TOOLS_DIR/verify_screenshots.py" \
    --directory "$DESTINATION" \
    --sizes "$($CONFIG sizes "$DISPLAY_TYPE" | paste -sd, -)"

echo "$DESTINATION に保存しました"
FINISHED=1
